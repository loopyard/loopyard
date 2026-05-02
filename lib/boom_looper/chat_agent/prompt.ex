defmodule BoomLooper.ChatAgent.Prompt do
  @moduledoc """
  System prompt construction for ChatAgent sessions.

  Pure functions that build the system prompt from the agent's type
  (a folder under `priv/agents/` or its user/project overrides), the
  workspace config, and the service context. No GenServer state needed.
  """
  require Logger

  alias BoomLooper.Agents.Registry

  # The system prompt is passed as a CLI argument (--system-prompt).
  # If it's too long, the OS will SIGKILL the CLI process (exit 137).
  # Keep it under this limit. Anything larger should go in CLAUDE.md
  # or a file the agent reads via `read_agent_file`.
  @max_system_prompt_chars 2000

  @doc """
  Build the system prompt for an agent session.

  `agent_type` identifies the folder under `priv/agents/` (or a
  user/project override). If the type can't be resolved, falls back
  to the default agent.
  """
  def build_system_prompt(agent_id, opts) when is_list(opts) do
    bind_mount = Keyword.get(opts, :bind_mount)
    workspace_id = Keyword.get(opts, :workspace_id)
    workspace = Keyword.get(opts, :workspace)
    service_name = Keyword.get(opts, :service_name)
    agent_type = Keyword.get(opts, :agent_type) || Registry.default_agent_name()

    parts = [
      base_prompt(agent_id, bind_mount, workspace_id),
      agent_definition(agent_type),
      workspace_prompt(workspace),
      service_prompt(service_name, workspace_id)
    ]

    prompt =
      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if String.length(prompt) > @max_system_prompt_chars do
      Logger.warning(
        "[ChatAgent] System prompt is #{String.length(prompt)} chars " <>
          "(limit #{@max_system_prompt_chars}). CLI may be SIGKILL'd. " <>
          "Move content into agent files or CLAUDE.md."
      )
    end

    prompt
  end

  @doc false
  def base_prompt(agent_id, _bind_mount, workspace_id) do
    container =
      if workspace_id do
        BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")
      else
        "bl-unknown-workspace-1"
      end

    """
    Workspace container: #{container}. YOUR AGENT ID: #{agent_id}. Pass agent_id to every tool call.

    Use boom-looper-container MCP tools for ALL work. `exec` for shell commands (output streams live, use timeout for long-running ones). ALWAYS use the `docker_compose` MCP tool — never run `docker compose` via Bash. /workspace is a Docker volume that persists across container restarts. Dev server runs in a separate container — use `logs` and `service_status` to check it.

    Long command output is truncated — you'll see the last ~80 lines. The full output is visible to the user in the chat.

    File operations — use the dedicated MCP tools, not shell commands:
    - `file_info` before reading unfamiliar files — tells you line count so you can decide: small (<100 lines) → read whole thing, large → use line range or grep first
    - `read_file` (with start_line/end_line) or `read_files` instead of `cat` — avoids dumping huge files into context
    - `edit` instead of `sed` — surgical find/replace, returns the changed region so you can verify without re-reading
    - `grep` (with context_lines=5) instead of grep→read_file — one call shows matches with surrounding code
    - `glob` and `tree` instead of `exec find` or `ls -R`
    Efficient pattern: grep to find → edit to fix. Skip the read_file in between — edit uses old_string matching, not line numbers.
    Tools with large result sets are paginated — if the output says "use offset=N for next page", pass that offset or refine your query.

    IMPORTANT: Container ports (e.g. 3000) are NOT accessible from the host. Docker maps them to random host ports. Use `probe_http` to find the real URL, or `service_containers` to see port mappings (e.g. 127.0.0.1:32794->3000/tcp means the app is at localhost:32794).

    Git: .git is NOT in the container — it lives on the host. Use the `git` MCP tool for all git operations (status, diff, add, commit, log). Never run `git` via `exec` inside the container.

    Linking files and the app in your replies:
    - To link a file, CALL the `file_url` MCP tool with path — it RETURNS a URL string like `/projects/abc/workspaces/def/volumes/code-xyz/files/app/models/user.rb`. Put THAT returned URL inside `[path](url)`. Never write `file_url(...)` literally in your markdown — that's the tool call syntax, not the link target.
    - Every source file path you mention MUST become a link this way. 10 files = 10 tool calls = 10 links.
    - For the running app, call `app_url` the same way — get a URL back, embed it.
    """
  end

  @doc false
  def agent_definition(agent_type) do
    case Registry.get(agent_type) do
      {:ok, agent} ->
        body = agent.body || ""
        catalog_str = catalog_section(agent)
        [body, catalog_str] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

      {:error, _} ->
        Logger.warning(
          "[ChatAgent] Unknown agent_type #{inspect(agent_type)}; using empty definition"
        )

        ""
    end
  end

  defp catalog_section(agent) do
    case Registry.catalog(agent) do
      [] -> ""
      files -> "Agent files (use `read_agent_file`): " <> Enum.join(files, ", ")
    end
  end

  @doc false
  def workspace_prompt(nil), do: ""

  def workspace_prompt(workspace) do
    name = Map.get(workspace, :name) || "Unnamed"
    custom = Map.get(workspace, :system_prompt)

    custom_block = if custom, do: "\n#{custom}", else: ""
    "## Workspace: #{name}#{custom_block}"
  end

  @doc false
  def service_prompt(nil, _), do: ""
  def service_prompt(_, nil), do: ""

  def service_prompt(service_name, workspace_id) do
    container =
      BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, service_name)

    "Service agent for #{service_name} (container: #{container}). Use `logs` to check output."
  end
end
