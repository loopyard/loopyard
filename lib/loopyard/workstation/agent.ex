defmodule Loopyard.Workstation.Agent do
  @moduledoc """
  The **workstation agent** — a singleton `ChatAgent` that configures the user's
  base image conversationally from the Workstation page. "Add the aws cli", and
  it edits the Dockerfile + rebuilds while you watch.

  It is NOT a workspace agent: `workspace_id: nil`, so it starts under the global
  `Loopyard.AgentSupervisor` and skips the workspace boot saga entirely. It gets
  a custom toolkit (`Tools.Workstation`) and a custom system prompt (the override
  path in `ChatAgent.Prompt`) instead of the workspace/container defaults.

  Single-user MVP: one fixed id, one agent. Per-user is a later refinement.
  """
  alias Loopyard.ChatAgent
  alias Loopyard.Workstation.Image

  @id "workstation"
  @name "Workstation"

  @doc "The fixed agent id for the workstation agent."
  def id, do: @id

  @doc """
  Ensure the workstation agent is running. Idempotent — returns `{:ok, id}` if it
  is already alive, otherwise starts it fresh under the global AgentSupervisor.

  Call this off the LiveView process (it boots a Claude CLI session, which blocks).
  """
  @spec ensure_started() :: {:ok, String.t()} | {:error, term()}
  def ensure_started do
    if alive?() do
      {:ok, @id}
    else
      ensure_supervisor()

      # Seed the Dockerfile so the agent's working_dir exists + read_dockerfile works.
      _ = Image.read_dockerfile()

      opts = [
        id: @id,
        name: @name,
        working_dir: Image.dir(),
        started_by: "browser",
        # No workspace_id → global supervisor, no workspace coupling.
        tools: [Loopyard.Tools.Workstation],
        system_prompt: system_prompt()
      ]

      case DynamicSupervisor.start_child(Loopyard.AgentSupervisor, {ChatAgent, opts}) do
        {:ok, _pid} -> {:ok, @id}
        {:error, {:already_started, _pid}} -> {:ok, @id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The global AgentSupervisor is declared in the app tree, but start it
  # on-demand too so this works on an already-running server (dev hot-reload,
  # before a restart picks up the application.ex entry). Idempotent.
  defp ensure_supervisor do
    if is_nil(Process.whereis(Loopyard.AgentSupervisor)) do
      spec = %{
        id: Loopyard.AgentSupervisor,
        start:
          {DynamicSupervisor, :start_link,
           [[name: Loopyard.AgentSupervisor, strategy: :one_for_one]]},
        type: :supervisor
      }

      case Supervisor.start_child(Loopyard.Supervisor, spec) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> :ok
        _ -> :ok
      end
    end

    :ok
  end

  @doc "Is the workstation agent's GenServer alive?"
  @spec alive?() :: boolean()
  def alive? do
    case Registry.lookup(Loopyard.ChatAgentRegistry, @id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  end

  # Kept well under ChatAgent.Prompt's 2000-char limit (longer → CLI SIGKILL).
  defp system_prompt do
    """
    YOUR AGENT ID: #{@id} — pass agent_id to every tool call.

    You configure the user's WORKSTATION: the Docker image every coding agent (and the user's console) is stamped from. Talk like a helpful sysadmin pairing with the user.

    The model has two layers — keep them straight:
    - IMAGE (you own this): tools + system packages, defined in the Dockerfile. Durable, shared by every agent. Edit it + rebuild to change what's installed everywhere.
    - $HOME volume (NOT yours): the user's logins (gh/claude/fly), dotfiles, language versions. You never put credentials or `*auth login` in the Dockerfile.

    Cattle, not pets: anything worth keeping goes in the Dockerfile. Install to system paths (/usr/local, apt) — NEVER $HOME, which the volume shadows. Base is debian:bookworm-slim.

    Your tools (loopyard-workstation):
    - read_dockerfile — always read before editing, to preserve what's there.
    - console — run a command in the live container to TEST it (e.g. confirm an apt package name). Ephemeral; gone on rebuild.
    - write_dockerfile — replace the whole Dockerfile with your edit (not a patch).
    - rebuild_image — apply it. Output streams to the page; every agent re-stamps from the result.

    Typical loop: read_dockerfile → (optionally console-test the install) → write_dockerfile with the new line in a sensible spot → rebuild_image → report what changed. Be concise. Confirm before destructive edits (removing tools, big rewrites).
    """
  end
end
