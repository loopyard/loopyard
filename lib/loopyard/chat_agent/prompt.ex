defmodule Loopyard.ChatAgent.Prompt do
  @moduledoc """
  System prompt construction for ChatAgent sessions.

  Pure functions that build the system prompt from the single agent
  definition (`priv/agents/coding/`), the workspace config, and the
  service context. No GenServer state needed.
  """
  require Logger

  alias Loopyard.Agents.Coding

  # The system prompt is passed as a single `--append-system-prompt` CLI arg.
  # The real OS cap on one argument is ~128KB (Linux MAX_ARG_STRLEN; macOS
  # ARG_MAX is 256KB total) — a normal multi-KB prompt is nowhere near it.
  #
  # So this is a *runaway guardrail*, NOT a hard SIGKILL boundary: if a prompt
  # blows past it, something (a whole file, a giant agent definition) leaked in
  # and should move into CLAUDE.md or a file read via `read_agent_file`. The old
  # 2000 value was wrong — it false-alarmed on every normal agent (the default
  # prompt alone is ~3.2KB), which is misleading log noise, not a real risk.
  @max_system_prompt_chars 16_000

  @doc """
  Build the system prompt for an agent session: the base prompt + the single
  coding agent's definition (`Loopyard.Agents.Coding`) + workspace/service
  context. A custom `:system_prompt` opt (e.g. the Workstation agent) overrides
  the whole thing.
  """
  def build_system_prompt(agent_id, opts) when is_list(opts) do
    case Keyword.get(opts, :system_prompt) do
      override when is_binary(override) and override != "" ->
        # Custom agents (e.g. the Workstation agent) supply a COMPLETE prompt and
        # skip the workspace/container scaffolding entirely. Still length-checked.
        warn_if_too_long(override)
        override

      _ ->
        build_default_system_prompt(agent_id, opts)
    end
  end

  defp build_default_system_prompt(agent_id, opts) do
    bind_mount = Keyword.get(opts, :bind_mount)
    workspace_id = Keyword.get(opts, :workspace_id)
    workspace = Keyword.get(opts, :workspace)
    service_name = Keyword.get(opts, :service_name)

    parts = [
      base_prompt(agent_id, bind_mount, workspace_id),
      agent_definition(),
      workspace_prompt(workspace),
      service_prompt(service_name, workspace_id)
    ]

    prompt =
      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    warn_if_too_long(prompt)
    prompt
  end

  defp warn_if_too_long(prompt) do
    if String.length(prompt) > @max_system_prompt_chars do
      Logger.warning(
        "[ChatAgent] System prompt is #{String.length(prompt)} chars " <>
          "(limit #{@max_system_prompt_chars}). CLI may be SIGKILL'd. " <>
          "Move content into agent files or CLAUDE.md."
      )
    end
  end

  @doc false
  def base_prompt(agent_id, _bind_mount, workspace_id) do
    """
    YOUR AGENT ID: #{agent_id} — pass agent_id to every tool call. Workspace: #{workspace_id}.

    You work in an always-on, lightweight container; the code is at /workspace (a Docker volume that persists across restarts). Use loopyard-container MCP tools for ALL work — `exec` for shell commands (output streams live; use timeout for long-running ones).

    Dev-service cluster (dev server, postgres, …): none runs by default. To RUN the app, write `.loopyard/workspace/docker-compose.yml` and bring it up with the `docker_compose` tool (never `docker compose` via `exec`). Check running services with `service_containers`/`workspace_info`; `logs` for output.

    Decisions: call `ask_user` (clickable buttons, waits) instead of asking in prose. Secrets: when you need an API key/token/password, call `request_secret` (masked field, kept OUT of the chat) — never ask the user to paste a secret into the conversation. It returns a storage key; read the value with `get_secret` only when you actually need it (ideally to set an env var right before the command that needs it). Branching: `propose_fork` to try an idea on a new branch workspace; `propose_integrate` to merge this branch into main; `propose_delete_workspace` to clean up after. All user-approved — never branch on your own.

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

    Git: use the `git` MCP tool for ALL git operations (status, diff, add, commit, log, merge, rebase) — it runs against this branch's repo. Commit your work as you go so it can be merged back. Don't run `git` via `exec`.

    Linking files and the app in your replies:
    - To link a file, CALL the `file_url` MCP tool with path — it RETURNS a URL string like `/projects/abc/workspaces/def/volumes/code-xyz/files/app/models/user.rb`. Put THAT returned URL inside `[path](url)`. Never write `file_url(...)` literally in your markdown — that's the tool call syntax, not the link target.
    - Every source file path you mention MUST become a link this way. 10 files = 10 tool calls = 10 links.
    - For the running app, call `app_url` the same way — get a URL back, embed it.
    """
  end

  @doc false
  def agent_definition do
    case Coding.definition() do
      {:ok, agent} ->
        body = agent.body || ""
        catalog_str = catalog_section()
        [body, catalog_str] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

      {:error, reason} ->
        Logger.warning("[ChatAgent] Could not load the coding agent definition: #{inspect(reason)}")
        ""
    end
  end

  defp catalog_section do
    case Coding.catalog() do
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
      Loopyard.Workspace.ServiceManager.service_container_name(workspace_id, service_name)

    "Service agent for #{service_name} (container: #{container}). Use `logs` to check output."
  end
end
