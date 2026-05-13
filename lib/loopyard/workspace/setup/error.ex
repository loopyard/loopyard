defmodule Loopyard.Workspace.Setup.Error do
  @moduledoc """
  Classifies raw saga step errors into structured error maps that the UI
  can render and `Loopyard.Retry` can use to decide whether to retry.

  Two responsibilities:

  1. **transient classification** — given a raw error, decide whether the
     setup coordinator should retry (network blips, daemon hiccups) or
     give up immediately (disk full, missing path, bad permissions).

  2. **operator-facing translation** — produce a structured error map
     with `code`, `why`, `consequence`, and `action` fields. UI surfaces
     `why` as the headline, `consequence` as the body, and `action` as
     the call-to-action — matching the WHY/CONSEQUENCE/ACTION rule from
     `plans/agent-sanity.md`.

  Both responsibilities are served by `classify/2`. Callers ignore the
  parts they don't need.
  """

  @typedoc "Structured error map produced by `classify/2`."
  @type t :: %{
          code: atom(),
          phase: atom(),
          why: String.t(),
          consequence: String.t(),
          action: String.t(),
          transient?: boolean(),
          raw: term()
        }

  @doc """
  Classify a raw saga step failure for `phase` into a structured map.

  `raw` is whatever the saga step's `:run` function returned as the error
  reason. Most concretely this is a Docker stderr blob, a `File.write`
  posix atom, or a `{:exception, message}` tuple from a step that raised.
  """
  @spec classify(term(), atom()) :: t()
  def classify(raw, phase) do
    {code, transient?} = categorize(raw)
    structured(code, phase, raw, transient?)
  end

  @doc """
  Convenience: just the transient flag. Used as the `:transient?` opt to
  `Loopyard.Retry.run/2` so the retry classifier and the UI classifier
  share the same logic.
  """
  @spec transient?(term(), atom()) :: boolean()
  def transient?(raw, phase) do
    classify(raw, phase).transient?
  end

  # ── Categorization ──

  # Order matters: more specific patterns first.
  defp categorize(raw) when is_binary(raw) do
    cond do
      contains_any?(raw, ["No space left on device", "ENOSPC"]) ->
        {:disk_full, false}

      contains_any?(raw, ["Permission denied", "read-only file system"]) ->
        {:permissions, false}

      contains_any?(raw, [
        "Repository not found",
        "could not read from remote",
        "Authentication failed"
      ]) ->
        {:invalid_git_url, false}

      contains_any?(raw, ["Remote branch", "not found in upstream"]) ->
        {:branch_not_found, false}

      contains_any?(raw, ["Cannot connect to the Docker daemon", "error during connect"]) ->
        {:docker_daemon_unreachable, true}

      contains_any?(raw, ["pull access denied", "failed to resolve reference", "i/o timeout"]) ->
        {:image_pull_failure, true}

      contains_any?(raw, [
        "Failed to connect",
        "network is unreachable",
        "Connection timed out",
        "RPC failed",
        "Could not resolve host"
      ]) ->
        {:network_timeout, true}

      contains_any?(raw, ["timed out"]) ->
        {:network_timeout, true}

      true ->
        {:unknown, false}
    end
  end

  defp categorize({:exception, msg}), do: categorize(msg)
  defp categorize({:exit, _}), do: {:unknown, false}
  defp categorize({:throw, _}), do: {:unknown, false}
  defp categorize(:enoent), do: {:source_path_missing, false}
  defp categorize(:eacces), do: {:permissions, false}
  defp categorize(:enospc), do: {:disk_full, false}
  defp categorize(:interrupted_by_restart), do: {:interrupted_by_restart, false}
  defp categorize(:source_path_missing), do: {:source_path_missing, false}
  defp categorize(:already_running), do: {:already_running, false}
  defp categorize({:source_path_missing, _path}), do: {:source_path_missing, false}
  defp categorize({:bad_return, _}), do: {:unknown, false}
  defp categorize({:step_failed, _, reason}), do: categorize(reason)
  defp categorize(_), do: {:unknown, false}

  defp contains_any?(text, needles) do
    Enum.any?(needles, &String.contains?(text, &1))
  end

  # ── Structured error map per code ──

  defp structured(:disk_full, phase, raw, _transient?) do
    %{
      code: :disk_full,
      phase: phase,
      why:
        "Could not write project files into the workspace volume — the Docker host's disk is full.",
      consequence:
        "The workspace can't be set up until disk space is freed. Agents won't start; chat is disabled.",
      action:
        "Free disk on the Docker host (try `docker system prune` or remove unused images / volumes), then click Retry.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:permissions, phase, raw, _transient?) do
    %{
      code: :permissions,
      phase: phase,
      why:
        "Could not read or write files during workspace setup — a path was rejected for permissions.",
      consequence: "The workspace can't be set up until the path is readable/writable.",
      action:
        "Check the source path's permissions (and the Docker host's filesystem), then click Retry.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:source_path_missing, phase, raw, _transient?) do
    %{
      code: :source_path_missing,
      phase: phase,
      why: "The source directory for this workspace no longer exists on disk.",
      consequence: "There's nothing to copy into the volume. The workspace can't be set up.",
      action:
        "Restore the source directory at its original path, or remove this workspace and add it again from the correct location.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:invalid_git_url, phase, raw, _transient?) do
    %{
      code: :invalid_git_url,
      phase: phase,
      why:
        "Git could not access the repository — it doesn't exist, is private, or your credentials were rejected.",
      consequence: "The clone can't proceed. The workspace can't be set up.",
      action: "Verify the repository URL and your auth (SSH key or token), then click Retry.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:branch_not_found, phase, raw, _transient?) do
    %{
      code: :branch_not_found,
      phase: phase,
      why: "The branch you asked to clone doesn't exist on the remote.",
      consequence: "The clone can't proceed.",
      action:
        "Pick an existing branch (or push the branch upstream first), then add the workspace again.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:docker_daemon_unreachable, phase, raw, _transient?) do
    %{
      code: :docker_daemon_unreachable,
      phase: phase,
      why:
        "Loopyard can't reach the Docker daemon — it may be stopped, restarting, or misconfigured.",
      consequence: "Volumes can't be created or written to. The workspace can't be set up.",
      action: "Make sure Docker (or Colima / OrbStack) is running, then click Retry.",
      transient?: true,
      raw: raw
    }
  end

  defp structured(:image_pull_failure, phase, raw, _transient?) do
    %{
      code: :image_pull_failure,
      phase: phase,
      why: "Docker couldn't pull the Alpine image used to copy files into the workspace volume.",
      consequence: "The seed step can't run. This is usually a network or registry hiccup.",
      action: "Check connectivity to your container registry, then click Retry.",
      transient?: true,
      raw: raw
    }
  end

  defp structured(:network_timeout, phase, raw, _transient?) do
    %{
      code: :network_timeout,
      phase: phase,
      why: "A network operation timed out during workspace setup.",
      consequence: "The current attempt couldn't finish.",
      action:
        "We auto-retry transient errors; if this fails repeatedly, check your network and click Retry.",
      transient?: true,
      raw: raw
    }
  end

  defp structured(:interrupted_by_restart, phase, raw, _transient?) do
    %{
      code: :interrupted_by_restart,
      phase: phase,
      why: "Loopyard restarted while this workspace was still being set up.",
      consequence:
        "The volume may be partially populated. No data has been lost — the safe option is to retry from the failed phase.",
      action: "Click Retry to resume setup.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:already_running, phase, raw, _transient?) do
    %{
      code: :already_running,
      phase: phase,
      why: "Setup is already running for this workspace.",
      consequence: "Duplicate setup is suppressed.",
      action: "Wait for the in-flight setup to finish.",
      transient?: false,
      raw: raw
    }
  end

  defp structured(:unknown, phase, raw, _transient?) do
    %{
      code: :unknown,
      phase: phase,
      why: "Workspace setup failed with an unrecognized error: #{summarize(raw)}",
      consequence: "We don't auto-retry unrecognized errors.",
      action:
        "Check /system/events for details, then click Retry. If this keeps happening, please report it.",
      transient?: false,
      raw: raw
    }
  end

  defp summarize(raw) when is_binary(raw) do
    raw
    |> String.split("\n")
    |> Enum.find(fn line -> String.trim(line) != "" end)
    |> Kernel.||("")
    |> String.slice(0, 240)
  end

  defp summarize(raw), do: inspect(raw, limit: 5, printable_limit: 240)
end
