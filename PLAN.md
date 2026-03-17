# Hive Architecture Plan — Containerized Agents with Tool Modules

## The Four Components

### 1. Hive (Elixir/Phoenix)
The control plane. Runs on the host (or its own container). Manages everything.
- Serves the chat UI (LiveView)
- Manages agent lifecycle (start, stop, rename)
- Hosts tool modules that agents call
- Spawns/destroys Docker containers
- Spawns/controls browsers

### 2. Dev Environment (Docker container, one per agent)
The agent's sandbox. Claude's bash/file operations happen here.
- Each agent gets its own container
- Has git, node, python, whatever the project needs
- Filesystem is isolated — agent can only see its own project
- Claude CLI runs inside this container
- The container is the security boundary — no permissions needed

### 3. Browser (Elixir process on Hive host)
Driven by the agent through tool modules. NOT inside Docker.
- Hive spawns a headless browser (Playwright/Wallaby/ChromeDriver)
- Agent calls functions like `Browser.visit/1`, `Browser.screenshot/0`
- Browser can reach the web server inside the agent's container via exposed ports
- Screenshots returned to the agent as base64 or file paths

### 4. Web Server (inside Dev Environment container)
The thing the agent is building/testing.
- Runs inside the agent's Docker container (e.g. `mix phx.server`, `npm run dev`)
- Port mapped to host so the browser can reach it
- Agent starts/stops it through tool modules that exec into the container

## Tool Module Pattern

Plain Elixir modules. Public functions with `@doc` strings. No MCP, no protocol.

```elixir
defmodule Hive.Tools.Agent do
  @doc "List all running agents with their IDs and names"
  def list(), do: ...

  @doc "Spawn a new agent with the given name and working directory"
  def spawn(name, working_dir), do: ...

  @doc "Send a message to another agent"
  def send_message(agent_id, message), do: ...

  @doc "Stop an agent"
  def stop(agent_id), do: ...
end

defmodule Hive.Tools.Browser do
  @doc "Navigate to a URL and return the page text"
  def visit(url), do: ...

  @doc "Take a screenshot, returns base64 PNG"
  def screenshot(), do: ...

  @doc "Click the element matching the CSS selector"
  def click(selector), do: ...

  @doc "Type text into the element matching the CSS selector"
  def fill(selector, value), do: ...

  @doc "Get the current page HTML"
  def html(), do: ...
end

defmodule Hive.Tools.DevServer do
  @doc "Start the dev server in the agent's container"
  def start(agent_id, command \\ "npm run dev"), do: ...

  @doc "Stop the dev server"
  def stop(agent_id), do: ...

  @doc "Get the URL to reach the dev server from the browser"
  def url(agent_id), do: ...
end

defmodule Hive.Tools.Container do
  @doc "Run a command in the agent's container, returns stdout"
  def exec(agent_id, command), do: ...

  @doc "Copy a file from host into the container"
  def copy_in(agent_id, host_path, container_path), do: ...

  @doc "Copy a file from container to host"
  def copy_out(agent_id, container_path, host_path), do: ...
end
```

## How Agents Discover Tools

The system prompt includes the module docs. When ChatAgent starts, it:
1. Collects all modules under `Hive.Tools.*`
2. Extracts their `@doc` and function signatures
3. Injects them into the Claude system prompt

Claude sees something like:
```
You have access to the following Elixir tool modules. Call them by name.

## Hive.Tools.Browser
- visit(url) — Navigate to a URL and return the page text
- screenshot() — Take a screenshot, returns base64 PNG
- click(selector) — Click the element matching the CSS selector
...
```

When Claude wants to use a tool, it outputs a function call. Hive parses it, executes the public function, returns the result. Private functions are invisible.

## How Tool Calls Work

Option A: Claude outputs structured tool calls (the SDK already supports this via `allowed_tools`)
Option B: Claude outputs Elixir expressions, Hive evals them in a restricted scope

Option A is cleaner — the SDK tool system already handles the call/response cycle. We'd register each public function as a tool. The SDK's `mcp_servers` option actually does this, but we don't need the MCP protocol — we just need the tool registration part.

Need to investigate: does the SDK support registering plain functions as tools without MCP?

If not, Option B works: inject tool docs into system prompt, parse Claude's output for function calls, eval in a sandbox that only has the tool modules in scope.

## Docker Container Lifecycle

```
Agent created → Docker container started → Claude CLI started inside container
                                         → Port exposed for web server
Agent message → Claude processes in container → May call host tools via SDK
Agent stopped → Claude CLI stopped → Container destroyed
```

Container image: pre-built with `claude` CLI + common dev tools (git, node, python, etc.)

### Docker Commands (via Elixir `System.cmd` or a Docker Elixir library)
- `docker run -d --name hive-agent-{id} -p {port}:3000 hive-dev-env`
- `docker exec hive-agent-{id} claude --input-format stream-json --output-format stream-json`
- `docker stop hive-agent-{id}`
- `docker rm hive-agent-{id}`

## Implementation Order

### Phase 1: Tool Module Infrastructure
- [ ] Define the `Hive.Tools` behaviour/pattern
- [ ] Auto-discovery of tool modules and doc extraction
- [ ] System prompt injection with tool descriptions
- [ ] Tool call execution (whichever option works — SDK tools or eval)
- [ ] Tests for tool discovery and execution

### Phase 2: Docker Integration
- [ ] Dockerfile for dev environment (claude CLI + dev tools)
- [ ] Container lifecycle management (start/stop/destroy)
- [ ] ChatAgent spawns claude inside Docker instead of locally
- [ ] Port mapping for web server access
- [ ] Tests for container lifecycle

### Phase 3: Browser Tools
- [ ] Pick a browser automation library (Wallaby? Playwright via port?)
- [ ] Implement Browser tool module
- [ ] Connect browser to container's web server
- [ ] Screenshot support
- [ ] Tests for browser tools

### Phase 4: Agent-to-Agent Tools
- [ ] Implement Agent tool module
- [ ] Allow agents to spawn/message other agents
- [ ] Tests for multi-agent workflows

## Open Questions

1. **SDK tool registration**: Can we register plain Elixir functions as tools without MCP? Need to check the `claude_code` SDK source.
2. **Browser library**: Wallaby (Elixir-native, uses ChromeDriver) vs Playwright (more capable, but needs Node.js bridge)?
3. **Container base image**: What tools should be pre-installed? Should it be configurable per agent?
4. **Port allocation**: Static port range? Dynamic allocation? Use Docker's random port mapping?
5. **File persistence**: Containers are ephemeral. Should we mount volumes for project files?
