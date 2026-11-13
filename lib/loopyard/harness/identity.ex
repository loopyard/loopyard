defmodule Loopyard.Harness.Identity do
  @moduledoc """
  Delivers an agent's **account** to its harness launch — the per-agent half
  of "which workstation pays for this agent".

  A work container mounts ONE identity's `$HOME` (the workspace's workstation,
  `Workspace.workstation_id/1`), whose env `~/.profile` sources. An agent
  stamped with a different `workstation_identity` needs that identity's env in
  the same container, so before every ACP session start this module
  materializes it as `~/.loopyard/env.<identity>` in the host identity's home
  volume (`Workstation.Env.sync_identity_into/2`); the launch script then
  sources it after `~/.profile` (`Harness.ACP.docker_exec_cmd/3`). The token
  travels as a file in the volume, never on the `docker exec` command line.
  A file-shaped sign-in (Codex's `auth.json`, `Workstation.CredentialFile`)
  rides the same sync: it lands at `~/.loopyard/codex.<identity>/` — only when
  absent or newly signed in, so a copy the CLI refreshed in place is kept — and
  the env file exports `CODEX_HOME` at it.

  Called from the two places a harness is started — `Initializer.start_session/3`
  (first boot + resume) and `SessionManager.start_session_safe/1` (every
  restart) — so a credential push for the agent's identity
  (`Env.put` → `Workstation.reload_agents` → `:credentials` restart) lands in
  the file the relaunch reads. Best-effort: a sync failure is logged and the
  launch proceeds on whatever the volume already holds (the previous file, or
  the profile env), which is never worse than before.
  """

  require Logger

  alias Loopyard.Workstation.Env

  @doc """
  Ensure the identity named in `session_opts` (`:workstation_identity`) has its
  env file in the launch container's home. A no-op unless the backend is the
  in-container ACP harness, the session has a container, and the identity
  differs from the container's host identity (whose own files `Env.sync_home/1`
  keeps current at container create + every credential push).
  """
  @spec deliver(module(), keyword()) :: :ok
  def deliver(Loopyard.Harness.ACP, session_opts) do
    identity = Keyword.get(session_opts, :workstation_identity)
    container = Keyword.get(session_opts, :container)

    with true <- is_binary(identity) and is_binary(container),
         host when is_binary(host) and host != identity <- host_identity(session_opts),
         true <- Loopyard.Docker.daemon_available?() do
      case Env.sync_identity_into(identity, host) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Harness.Identity] couldn't deliver #{identity}'s env into #{host}'s home " <>
              "(#{inspect(reason)}) — launching on what the volume already holds"
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  def deliver(_backend, _session_opts), do: :ok

  # The identity whose $HOME the launch container mounts: a workspace agent's
  # container mounts its workspace's workstation; a system agent's container
  # IS its identity's (nil → nothing to deliver).
  defp host_identity(session_opts) do
    case Keyword.get(session_opts, :workspace_id) do
      ws when is_binary(ws) -> Loopyard.Workspace.workstation_id(ws)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
