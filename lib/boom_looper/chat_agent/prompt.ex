defmodule BoomLooper.ChatAgent.Prompt do
  @moduledoc """
  System prompt construction for ChatAgent sessions.

  Pure functions that build the system prompt from agent identity,
  workspace config, and service context. No GenServer state needed.
  """
  require Logger

  # The system prompt is passed as a CLI argument (--system-prompt).
  # If it's too long, the OS will SIGKILL the CLI process (exit 137).
  # Keep it under this limit. Anything larger should go in CLAUDE.md
  # or a file the agent reads.
  @max_system_prompt_chars 2000

  @setup_guide File.read!(Path.join(:code.priv_dir(:boom_looper), "prompts/setup_guide.md"))

  @doc false
  def setup_guide, do: @setup_guide

  @doc false
  def build_system_prompt(agent_id, bind_mount, workspace_id, workspace, service_name) do
    # System prompt: ONLY identity + agent ID. Must stay small.
    base = if workspace do
      container_base_prompt(agent_id, bind_mount, workspace_id)
    else
      setup_base_prompt(agent_id, bind_mount)
    end

    parts = [base]

    parts = if workspace do
      parts ++ [workspace_prompt(workspace, bind_mount)]
    else
      parts ++ [setup_prompt(bind_mount)]
    end

    parts = if service_name && workspace_id && workspace do
      parts ++ [service_agent_prompt(service_name, workspace_id, workspace)]
    else
      parts
    end

    prompt = Enum.join(parts, "\n")

    if String.length(prompt) > @max_system_prompt_chars do
      Logger.warning(
        "[ChatAgent] System prompt is #{String.length(prompt)} chars " <>
        "(limit #{@max_system_prompt_chars}). CLI may be SIGKILL'd. " <>
        "Move content to priv/prompts/ or CLAUDE.md."
      )
    end

    prompt
  end

  @doc false
  def service_agent_prompt(service_name, workspace_id, _workspace) do
    # Workspace metadata no longer carries services/processes — that info
    # lives in docker-compose.yml directly. Just point the agent at the
    # right container and let it use `logs` / `exec` to investigate.
    container =
      BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, service_name)

    "\nService agent for #{service_name} (container: #{container}). Use `logs` to check output."
  end

  @doc false
  def container_base_prompt(agent_id, _bind_mount, workspace_id) do
    container =
      if workspace_id do
        BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")
      else
        "bl-unknown-workspace-1"
      end

    workspace_note = "/workspace is a Docker volume that persists across container restarts"

    """
    Workspace container: #{container}. YOUR AGENT ID: #{agent_id}. Pass agent_id to every tool call.

    Use boom-looper-container MCP tools for ALL work. `exec` for quick commands, `exec_stream` for long-running ones. ALWAYS use the `docker_compose` MCP tool — never run `docker compose` via Bash. #{workspace_note}. Dev server runs in a separate container — use `logs` and `service_status` to check it.

    Long command output is truncated — you'll see the last ~80 lines. The full output is visible to the user in the chat. Use `grep` or `read_file` for targeted lookups instead of dumping entire logs.

    IMPORTANT: Container ports (e.g. 3000) are NOT accessible from the host. Docker maps them to random host ports. Use `probe_http` to find the real URL, or `service_containers` to see port mappings (e.g. 0.0.0.0:32794->3000/tcp means the app is at localhost:32794).

    When the user asks to see, open, or view something, use `file_url`:
    - To show a file: `file_url(path: "app/models/user.rb")` → returns a link to the syntax-highlighted viewer
    - To show the running app: `file_url(path: "/users", mode: "app")` → returns a link with the correct host port
    Include the URL in your response as a markdown link so the user can click it.
    """
  end

  @doc false
  def workspace_prompt(workspace, _bind_mount) do
    custom = if workspace.system_prompt, do: "\n#{workspace.system_prompt}\n", else: ""

    """
    ## Workspace: #{workspace.name || "Unnamed"}
    #{custom}
    """
  end

  @doc false
  def setup_base_prompt(agent_id, _bind_mount) do
    """
    You are a Setup agent. YOUR AGENT ID: #{agent_id}

    Pass your agent_id "#{agent_id}" to every tool call.

    Steps: read project files → write Dockerfile → write docker-compose.yml → docker_compose up → exec setup → verify.

    Tools:
    - `write_file` — write Dockerfile and docker-compose.yml to `.boomlooper/workspace/`
    - `docker_compose` — run compose commands (e.g. "up -d --build", "ps", "logs dev")
    - `docker` — run docker commands (e.g. "ps", "volume ls")
    - `exec` — run commands in the workspace container
    - `logs` — get container logs

    CRITICAL: ALWAYS use the `docker_compose` MCP tool for compose commands. NEVER run `docker compose` via Bash or `exec`. The MCP tool sets the correct project name, syncs compose files, and streams output to the UI. Running compose directly creates containers with wrong names that the platform can't manage.

    Long command output is truncated — you'll see the last ~80 lines. The full output is visible to the user in the chat. Use `grep` or `read_file` for targeted lookups instead of dumping entire logs.

    Use `${CODE_VOLUME}:/workspace` in your compose file — it gets substituted automatically.

    """
  end

  @doc false
  def setup_prompt(bind_mount) do
    path_note = if bind_mount, do: " at #{bind_mount}", else: ""

    """
    ## Workspace Setup

    New project#{path_note}. Write docker-compose.yml and Dockerfile directly:
    1. Read project files to understand the stack
    2. `write_file` path=`.boomlooper/workspace/Dockerfile`
    3. `write_file` path=`.boomlooper/workspace/docker-compose.yml`
    4. `docker_compose("up -d --build")`
    5. `exec` to install deps/run migrations
    6. `docker_compose("logs dev")` to verify
    """
  end
end
