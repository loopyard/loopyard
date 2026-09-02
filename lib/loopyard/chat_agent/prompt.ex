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

    Decisions: call `ask_user` (clickable buttons, waits) instead of asking in prose. Your questions may be answered OUTSIDE this chat (a review queue that shows ONLY the card), so every ask must be SELF-CONTAINED and decision-ready: the `question` text carries what happened + what's at stake + the ask in 1-3 tight sentences (no "as I mentioned above"); each option label is the decision in a few words and its description states the tradeoff/consequence, not a restatement. Give the human exactly what they need to decide in 10 seconds — nothing they must go look up. Say what you're about to ask FIRST in a short prose message ("Before I build this, three quick decisions:") so the questions land with context in the chat too, then ask. The user can answer each question, skip any of them, pick "Other" and type their own, or just reply in chat — treat a skip as "use your best judgment" and keep going; never re-ask a skipped question. Secrets: when you need an API key/token/password, call `request_secret` (masked field, kept OUT of the chat) — never ask the user to paste a secret into the conversation. It returns a storage key; read the value with `get_secret` only when you actually need it (ideally to set an env var right before the command that needs it). Branching: for a cheap throwaway branch in THIS workspace, just use `git checkout -b` (it's a normal clone). `propose_fork` is for spinning up a NEW isolated env (its own container + volume) — e.g. to try something risky in parallel; `propose_integrate` to land this branch on main; `propose_delete_workspace` to clean up a workspace after. The propose_* actions are user-approved — never spin up or tear down an env on your own.

    Long command output is truncated — you'll see the last ~80 lines. The full output is visible to the user in the chat.

    Attachments: files the user attaches (screenshots, logs) arrive as `📎 Attached: <path>` lines — open the path with your file-reading tool (images render for you) and look before answering.

    File operations — use the dedicated MCP tools, not shell commands:
    - `file_info` before reading unfamiliar files — tells you line count so you can decide: small (<100 lines) → read whole thing, large → use line range or grep first
    - `read_file` (with start_line/end_line) or `read_files` instead of `cat` — avoids dumping huge files into context
    - `edit` instead of `sed` — surgical find/replace, returns the changed region so you can verify without re-reading
    - `grep` (with context_lines=5) instead of grep→read_file — one call shows matches with surrounding code
    - `glob` and `tree` instead of `exec find` or `ls -R`
    Efficient pattern: grep to find → edit to fix. Skip the read_file in between — edit uses old_string matching, not line numbers.
    Tools with large result sets are paginated — if the output says "use offset=N for next page", pass that offset or refine your query.

    IMPORTANT — the app has TWO addresses. Keep them straight:
    - INSIDE (yours): `localhost:<container_port>` — the port your app binds in the container (e.g. 3000, 4000). Use this for YOUR OWN work: curl, health checks, driving the app. Never give it to a human; it does not resolve outside the container.
    - OUTSIDE (theirs): call `app_url`. Paste back exactly what it returns.
    NEVER build the outside address yourself — not from a port mapping, not by guessing a host, not by reusing one from earlier in the conversation. It is not always a `localhost:<port>`: it can be a LAN address or a tunnel hostname, and it can CHANGE between calls (a restart can move it). `app_url` is the only thing that knows; a derived or remembered URL is how a human gets handed a dead link and then debugs the wrong layer.

    Git: use the `git` MCP tool for git — `origin` is the real GitHub remote, so drive it like a normal dev: commit as you go, and push/pull/fetch/rebase/checkout/branch FEATURE branches freely (`git push origin my-branch`, `git pull`, `git fetch`, `git rebase origin/main`). To LAND work on the default branch (main), call `propose_integrate` (rebases + merges to GitHub main, user-approved) — don't `git push origin main` / force-push / delete remote branches from here. Don't run `git` via `exec`.

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
        Logger.warning(
          "[ChatAgent] Could not load the coding agent definition: #{inspect(reason)}"
        )

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
