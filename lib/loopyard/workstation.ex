defmodule Loopyard.Workstation do
  @moduledoc """
  Named **workstations** — each one is a *person's identity*: their Dockerfile
  (image), their env vars, their logins (the `$HOME` volume). `brad`, `jamie`.
  Profile, user, and workstation are the same concept.

  You **operate as** a workstation (`current/0`); agents you spin up inherit it —
  its image, its creds, its name on commits. That's how an agent knows which
  image to use: it doesn't ask, it follows the driver's identity. See
  plans/integrations.md.

  On disk: `<LOOPYARD_HOME>/workstations/<id>/` holds `Dockerfile` + `env.json`.
  Docker holds the runtime: image `loopyard-ws-<id>`, volume `loopyard-ws-<id>-home`.
  """
  alias Loopyard.{Docker, VolumeManager, Workspace}

  @id_re ~r/^[a-z0-9][a-z0-9-]{0,38}$/

  @doc "Root of all workstation dirs."
  def base_dir, do: Path.join(Workspace.home_dir(), "workstations")

  @doc "Dir for one workstation: `<LOOPYARD_HOME>/workstations/<id>/`."
  def dir(id), do: Path.join(base_dir(), id)

  @doc "Is `id` a legal workstation id (lowercase, digits, dashes)?"
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_re, id)

  @doc "Does this workstation exist on disk?"
  def exists?(id), do: valid_id?(id) and File.dir?(dir(id))

  @doc "All workstation ids (sorted). Ensures at least one identity exists."
  def list do
    _ = ensure_bootstrap()

    case File.ls(base_dir()) do
      {:ok, entries} -> entries |> Enum.filter(&File.dir?(dir(&1))) |> Enum.sort()
      _ -> [default_id()]
    end
  end

  @doc "Create a workstation dir (seeds its full build context). Returns `:ok | {:error, _}`."
  def create(id) do
    cond do
      not valid_id?(id) ->
        {:error, :invalid_id}

      exists?(id) ->
        {:error, :exists}

      true ->
        File.mkdir_p!(dir(id))
        ensure_context(id)
        :ok
    end
  end

  @doc """
  Ensure a workstation's dir holds the full Docker **build context** — the
  Dockerfile (seeded if absent; preserved if the user/agent edited it) plus every
  sibling file the Dockerfile `COPY`s (e.g. `loopyard-open`), copied from the stock
  base in priv. Idempotent; safe to call before every build.
  """
  def ensure_context(id) do
    stock = Application.app_dir(:loopyard, "priv/workspace-base")

    case File.ls(stock) do
      {:ok, files} ->
        File.mkdir_p!(dir(id))

        Enum.each(files, fn f ->
          dest = Path.join(dir(id), f)
          # Dockerfile: only seed if absent; siblings: ensure present.
          unless File.exists?(dest), do: File.cp!(Path.join(stock, f), dest)
        end)

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Rename a workstation `old` → `new`: the on-disk dir, the `.current` pointer, and
  the Docker resources (container, image tag, `$HOME` volume) if they exist. The
  volume is migrated by copy (Docker can't rename volumes) so logins survive.
  Returns `:ok | {:error, reason}`.
  """
  def rename(old, new) do
    cond do
      not exists?(old) ->
        {:error, :not_found}

      not valid_id?(new) ->
        {:error, :invalid_id}

      exists?(new) ->
        {:error, :exists}

      true ->
        File.rename!(dir(old), dir(new))
        rename_docker(old, new)
        if current() == old, do: set_current(new)
        :ok
    end
  end

  @doc """
  Is the workstation's Claude credential dead? True when any agent is stuck
  in :auth_expired (or carries an auth_error) — the fleet-level "nothing will
  work until a human pushes a fresh token" signal. Drives the operator page's
  token mini-app; MUST work without any live agent (pure ETS read).
  """
  def claude_auth_broken? do
    Loopyard.ChatAgent.list_agent_summaries()
    |> Enum.any?(fn s -> s[:status] == :auth_expired or is_binary(s[:auth_error]) end)
  rescue
    _ -> false
  end

  @doc "The workstation you're operating as (the identity agents inherit)."
  def current do
    case File.read(current_path()) do
      {:ok, raw} ->
        id = String.trim(raw)
        if exists?(id), do: id, else: ensure_bootstrap()

      _ ->
        ensure_bootstrap()
    end
  end

  @doc "Switch the identity you operate as."
  def set_current(id) do
    cond do
      not exists?(id) ->
        {:error, :not_found}

      true ->
        File.mkdir_p!(base_dir())
        File.write!(current_path(), id)
        :ok
    end
  end

  @doc """
  Restart the harness session of every agent bound to this workstation — every
  workspace agent whose workspace resolves to `id`, plus the operator agent for
  `id`. Use this after pushing a fresh credential (e.g. a new
  `CLAUDE_CODE_OAUTH_TOKEN`) into the identity env: a *running* ACP/CLI session
  sourced its env at launch and holds the OLD token until it is restarted, so
  the volume-level `Env.sync_home` alone doesn't rescue an already-live session.

  Uses the `:credentials` reason: a token change can mean a DIFFERENT account,
  whose session store can't resume the old native session id — so the restart
  drops it and reconstructs the conversation from Loopyard's durable log (verbatim
  seed + the `recall_conversation` tool) rather than a doomed resume that boots
  the agent amnesic. History survives the switch; the restart is silent in chat
  (the harness-status sidebar covers the transient state). Best-effort per agent.
  """
  @spec reload_agents(String.t()) :: :ok
  def reload_agents(id) when is_binary(id) do
    operator_id = Loopyard.Operator.agent_id(id)

    Loopyard.ChatAgent.list_agents()
    |> Enum.filter(fn a ->
      a.id == operator_id or
        (is_binary(a[:workspace_id]) and agent_workstation(a[:workspace_id]) == id)
    end)
    |> Enum.each(fn a -> Loopyard.ChatAgent.restart_session(a.id, :credentials) end)

    :ok
  rescue
    _ -> :ok
  end

  # workstation_id/1 raises on unknown/malformed ids; never let that abort a reload.
  defp agent_workstation(ws_id) do
    Workspace.workstation_id(ws_id)
  rescue
    _ -> nil
  end

  # --- Docker naming (per identity) ---
  # Identity is the home volume; the toolchain is the shared base image, so there
  # is no per-identity image tag.
  def container_name(id), do: "loopyard-ws-#{id}"
  def home_volume(id), do: "loopyard-ws-#{id}-home"

  @doc """
  The id to bootstrap a fresh install with — your name, not a generic "default".
  Derived from `git config user.name` (first word) → `$USER` → "workstation".
  """
  def default_id do
    [derive(["git", "config", "user.name"]), System.get_env("USER"), "workstation"]
    |> Enum.map(&sanitize/1)
    |> Enum.find("workstation", &valid_id?/1)
  end

  # --- internals ---

  # Ensure at least one identity exists; return the operating-as default.
  defp ensure_bootstrap do
    id = default_id()

    existing =
      with {:ok, entries} <- File.ls(base_dir()), do: Enum.filter(entries, &File.dir?(dir(&1)))

    case existing do
      [first | _] ->
        first

      _ ->
        create(id)
        id
    end
  end

  defp current_path, do: Path.join(base_dir(), ".current")

  # Rename Docker resources for an identity if they exist. Container: rename.
  # Image: retag + drop old. Volume: copy into a new named volume, then remove old.
  defp rename_docker(old, new) do
    if Docker.container_exists?(container_name(old)) do
      _ = Docker.docker(["rename", container_name(old), container_name(new)])
    end

    if VolumeManager.volume_exists?(home_volume(old)) do
      migrate_volume(home_volume(old), home_volume(new))
    end

    :ok
  end

  defp migrate_volume(from, to) do
    _ = VolumeManager.create_volume(to)

    _ =
      Docker.docker([
        "run",
        "--rm",
        "-v",
        "#{from}:/from",
        "-v",
        "#{to}:/to",
        "alpine",
        "sh",
        "-c",
        "cp -a /from/. /to/ 2>/dev/null || true"
      ])

    _ = Docker.docker(["volume", "rm", from])
    :ok
  end

  # Run a command, return its trimmed stdout or nil.
  defp derive([cmd | args]) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # First whitespace token, downcased, stripped to the id charset. nil if unusable.
  defp sanitize(nil), do: nil

  defp sanitize(s) do
    s
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> case do
      nil -> nil
      word -> word |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "")
    end
  end
end
