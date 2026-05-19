defmodule Loopyard.AgentSandbox do
  @moduledoc """
  Loopyard-owned sandbox container per agent.

  Every workspace agent gets its own container built from
  `loopyard/agent-sandbox:<version>`, mounted on the workspace's
  code volume at `/workspace`, run with `--network none`. The
  container's lifecycle is bound to the agent's lifecycle —
  ensured at boot, stopped on agent stop/crash/reap.

  This module is stateless. It wraps `Loopyard.Docker` calls.
  Lifecycle decisions (when to start/stop) live in
  `Loopyard.AgentBoot` (saga) and `Loopyard.ChatAgent` (terminate).

  See `plans/agent-shell-container.md` for the design rationale.
  """

  alias Loopyard.Docker

  # Image version moves only when priv/agent-sandbox/Dockerfile
  # changes. Loopyard.AgentSandboxTest verifies this pin matches the
  # tagged build output.
  @image_version "0.1.0"
  @image_name "loopyard/agent-sandbox:#{@image_version}"

  # Cap container memory. Enough for ripgrep + jq + git ops on large
  # repos without OOM; low enough that N idle sandboxes don't add up
  # to real RAM cost. Validated empirically — re-tune if tools start
  # OOM-ing on large workspaces.
  @memory_limit "512m"

  @doc "Pinned image name + tag this Loopyard build uses."
  def image_name, do: @image_name

  @doc """
  Build the sandbox image locally from `priv/agent-sandbox/Dockerfile`.

  Idempotent — Docker's build cache makes re-runs cheap once the layers
  exist. Returns `:ok` on success, `{:error, reason}` on failure
  (missing docker, build error, etc.).

  Called by `mix loopyard.setup` and by `ensure_running/3` as a
  fallback when the image is missing locally.
  """
  def build_image do
    if System.find_executable("docker") do
      dockerfile_dir = Application.app_dir(:loopyard, ["priv", "agent-sandbox"])

      case Docker.docker(
             ["build", "-t", @image_name, dockerfile_dir],
             # Cold build with apk add takes ~30s; warm cache is seconds.
             timeout: 180_000
           ) do
        {:ok, _} -> :ok
        {:error, output} -> {:error, output}
      end
    else
      {:error, :docker_not_installed}
    end
  end

  @doc """
  Check whether the sandbox image is already present locally.
  """
  def image_present? do
    case Docker.docker(["image", "inspect", @image_name]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Deterministic container name for an agent. Compile-time stable —
  no probing, no lookups. Tools resolve this directly from the
  agent_id when they need a container target.
  """
  def container_name(workspace_id, agent_id)
      when is_binary(workspace_id) and is_binary(agent_id) do
    "loopyard-#{workspace_id}-agent-#{agent_id}"
  end

  @doc """
  Ensure the sandbox container exists and is running. Idempotent —
  safe to call multiple times. Returns `:ok` if the container is
  running afterward, `{:error, reason}` otherwise.

  Cases handled:

  - Container is already running → no-op, returns `:ok`.
  - Container exists but is stopped → starts it.
  - Container doesn't exist → creates and starts it.
  - Image is missing locally → returns
    `{:error, :image_unavailable}` (caller's job to pull/build).

  `volume_name` is the workspace code volume to mount at
  `/workspace`. Required because volumes are workspace-scoped and
  this function doesn't have a workspace registry to look it up.
  """
  def ensure_running(workspace_id, agent_id, volume_name)
      when is_binary(workspace_id) and is_binary(agent_id) and is_binary(volume_name) do
    name = container_name(workspace_id, agent_id)

    cond do
      Docker.container_running?(name) ->
        :ok

      Docker.container_exists?(name) ->
        start_existing(name)

      true ->
        create_and_start(name, workspace_id, agent_id, volume_name)
    end
  end

  @doc """
  Stop the sandbox container and remove it. Idempotent — if the
  container is already gone, returns `:ok`.
  """
  def stop(workspace_id, agent_id)
      when is_binary(workspace_id) and is_binary(agent_id) do
    name = container_name(workspace_id, agent_id)

    case Docker.docker(["rm", "-f", name], timeout: 30_000) do
      {:ok, _} ->
        :ok

      # Docker returns non-zero for "no such container" — also a success
      # state from our perspective.
      {:error, output} ->
        if output =~ "No such container" or output =~ "no such container" do
          :ok
        else
          {:error, output}
        end
    end
  end

  @doc """
  Check whether the sandbox container is currently running.
  Convenience wrapper for callers that don't want to construct the
  name themselves.
  """
  def running?(workspace_id, agent_id) do
    Docker.container_running?(container_name(workspace_id, agent_id))
  end

  # --- Private ---

  defp start_existing(name) do
    case Docker.docker(["start", name], timeout: 15_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp create_and_start(name, workspace_id, agent_id, volume_name) do
    args = [
      "run",
      "--detach",
      "--name",
      name,
      # Memory cap to prevent runaway sandbox from eating the host.
      "--memory=#{@memory_limit}",
      # No network. The sandbox does file I/O + local shell — never
      # outbound HTTP. Anything that needs network goes through
      # `docker_compose exec` into a properly-networked service.
      "--network",
      "none",
      # `--init` reaps zombie processes left behind by misbehaving
      # tool commands (e.g. an `exec` that spawns subprocesses).
      "--init",
      # Labels — keep these stable; Docker.Observer + the Janitor
      # may filter on them.
      "--label",
      "loopyard.sandbox=true",
      "--label",
      "loopyard.workspace_id=#{workspace_id}",
      "--label",
      "loopyard.agent_id=#{agent_id}",
      # Mount the workspace volume at /workspace. Same boundary as
      # every other workspace container — no host paths.
      "--volume",
      "#{volume_name}:/workspace",
      "--workdir",
      "/workspace",
      @image_name,
      "sleep",
      "infinity"
    ]

    case Docker.docker(args, timeout: 30_000) do
      {:ok, _} ->
        :ok

      {:error, output} ->
        cond do
          image_missing_error?(output) ->
            # Image isn't present locally and can't be pulled (no
            # public registry yet). Build it from priv/ and retry
            # once. This is the "user skipped mix loopyard.setup but
            # spawned an agent anyway" path — should Just Work.
            with :ok <- build_image(),
                 {:ok, _} <- Docker.docker(args, timeout: 30_000) do
              :ok
            else
              {:error, build_err} -> {:error, {:image_build_failed, build_err}}
            end

          output =~ "is already in use by container" ->
            # Concurrent ensure_running race — another caller won the
            # create. Try starting the existing one.
            start_existing(name)

          true ->
            {:error, {:create_failed, output}}
        end
    end
  end

  @image_missing_markers [
    "No such image",
    "Unable to find image",
    "manifest unknown",
    "pull access denied"
  ]

  defp image_missing_error?(output) do
    Enum.any?(@image_missing_markers, &String.contains?(output, &1))
  end
end
