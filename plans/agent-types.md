# Agent Types: composable agents with tools, computers, and gates

## Problem

All agents get the same tools and the same container today. A Setup agent has browser tools it doesn't need. A QA agent doesn't have browser tools it does need. A data agent needs Python and psql but gets a Ruby environment. There's no way to create a "Code Review" agent that only reads files and can't modify anything.

As we add more sidecar MCP servers (browser, secrets, databases, etc.), every agent getting every tool becomes noisy and confusing. Agents need to be composable.

## Design

### Agent = Name + Tools + Computer + Gates

An agent is defined by:
- **Name** — human-readable ("QA", "Setup", "Code Review", "Browser Dude")
- **Tools** — which MCP servers this agent gets (toggled on/off)
- **Computer** — what Dockerfile/container it runs in (its installed software, runtime, capabilities)
- **Gates** — which tools require human approval (see `plans/human-gates.md`)
- **System prompt** — optional custom instructions for this agent type

### Tool Server Metadata

Each toolkit module already has `__tool_server__/0` returning a name and tool list. Extend it with human-readable metadata:

```elixir
defmodule BoomLooper.Tools.Container do
  @tool_server %{
    id: "boom-looper-container",
    title: "Workspace Tools",
    description: "Read/write files, run commands, manage Docker services",
    icon: :terminal,
    tools: [Container.Exec, Container.WriteFile, ...]
  }
end

defmodule BoomLooper.Tools.Browser do
  @tool_server %{
    id: "boom-looper-browser",
    title: "Browser",
    description: "Take screenshots, navigate pages, test UI",
    icon: :globe,
    tools: [Browser.Screenshot, Browser.Navigate, ...]
  }
end
```

Each tool module already has `__tool_name__/0` and `__description__/0` from the `BoomLooper.Tool` macro — those become the per-tool detail view.

### "New Agent" Flow

1. **Name screen** — type a name or pick a preset
2. **Tool selection screen** — grid/list of available tool servers with:
   - Title + description (human-readable)
   - Toggle on/off
   - Expandable: click to see individual tools in that server
3. **Launch** — agent starts with exactly the selected MCP servers

```
┌──────────────────────────────────────────────┐
│  New Agent                                    │
│                                               │
│  Name: [QA Agent                           ]  │
│                                               │
│  Select tools:                                │
│                                               │
│  ☑ Workspace Tools              ▸ 21 tools   │
│    Read/write files, run commands,            │
│    manage Docker services                     │
│                                               │
│  ☑ Browser                      ▸ 3 tools    │
│    Take screenshots, navigate pages,          │
│    test UI                                    │
│                                               │
│  ☐ Secrets                      ▸ 2 tools    │
│    Access API keys and credentials            │
│                                               │
│  ☑ Agent Coordination           ▸ 6 tools    │
│    Spawn and message other agents             │
│                                               │
│               [ Launch Agent ]                │
└──────────────────────────────────────────────┘
```

### Presets

Common agent configurations saved as presets:

| Preset | Tools | Use case |
|--------|-------|----------|
| Setup | Workspace, Agents | Bootstrap a new project |
| Developer | Workspace, Agents | Write code, run tests |
| QA | Workspace, Browser, Agents | Test features visually |
| Code Review | Workspace (read-only subset) | Review PRs without modifying |
| Debug | Workspace, Browser, Agents | Investigate and fix issues |

Presets are just saved name + tool selection. Users can create custom presets. Presets can be per-project (stored in `.boomlooper/repo/`) or global (stored in `~/.boomlooper/presets/`).

### How it wires into ChatAgent

Today, `ChatAgent.ToolConfig` hardcodes the MCP servers:

```elixir
mcp_servers: %{
  "boom-looper-container" => BoomLooper.Tools.Container,
  "boom-looper-agents" => BoomLooper.Tools.Agents,
  "boom-looper-secrets" => BoomLooper.Tools.Secrets
}
```

With agent types, this becomes dynamic:

```elixir
# Agent opts include selected tool servers
agent_opts = [
  id: id,
  name: "QA Agent",
  tool_servers: ["boom-looper-container", "boom-looper-browser"],
  ...
]

# ToolConfig resolves to modules
mcp_servers = ToolConfig.resolve_servers(agent_opts[:tool_servers])
# => %{"boom-looper-container" => Container, "boom-looper-browser" => Browser}
```

### Tool Registry

A central registry of all available tool servers:

```elixir
defmodule BoomLooper.Tools.Registry do
  def available_servers do
    [
      BoomLooper.Tools.Container.__tool_server__(),
      BoomLooper.Tools.Agents.__tool_server__(),
      BoomLooper.Tools.Secrets.__tool_server__(),
      BoomLooper.Tools.Browser.__tool_server__()  # future
    ]
  end

  def resolve(server_ids) do
    Map.new(available_servers(), fn s -> {s.id, s.module} end)
    |> Map.take(server_ids)
  end
end
```

The "New Agent" screen reads from this registry. Adding a new tool server means adding one module — it automatically appears in the UI.

### Per-tool granularity (future)

Phase 1: toggle entire tool servers (Workspace, Browser, Agents).
Phase 2: toggle individual tools within a server. The "Code Review" agent gets Workspace Tools but with `write_file`, `edit`, `multi_edit`, `docker_compose` disabled — read-only access.

The `BoomLooper.Tool` macro already has the metadata. The `allowed_tools` list in Claude Code session opts already supports per-tool filtering. Just need the UI to expose it.

### System prompt per agent type

Each preset/type can carry a system prompt fragment:

- **Setup**: "You are a Setup agent. Bootstrap the dev environment..."
- **QA**: "You are a QA agent. Test features visually using the browser tools. Take screenshots after each change..."
- **Code Review**: "You are a Code Review agent. Read the code, identify issues, suggest improvements. Do NOT modify files."

This already exists (`ChatAgent.Prompt.build_system_prompt`) — just needs to accept the agent type's prompt fragment alongside the workspace config.

### Computer: the agent's container

The Dockerfile IS the agent's capability declaration. Today every agent
shares the same workspace container. With agent types, each type gets its
own container definition.

**Why separate containers:**
- A QA agent needs Chromium (~130MB). The developer agent doesn't.
- A data agent needs Python + pandas + psql client. The setup agent doesn't.
- A code review agent needs nothing but the source code and a linter. Tiny image.
- Isolation: a runaway agent can't trash another agent's environment.

**How it works:**

Each agent type has a Dockerfile (or references a base image):

```elixir
%AgentType{
  name: "QA",
  tools: ["boom-looper-container", "boom-looper-browser"],
  computer: %{
    dockerfile: "FROM mcr.microsoft.com/playwright:v1.40.0-focal\nRUN npm i -g playwright",
    # OR reference a pre-built image:
    image: "bl-qa-agent:latest",
    # The code volume is always mounted at /workspace
    volumes: ["${CODE_VOLUME}:/workspace"],
    # Internal network access to other services
    networks: ["default"]
  },
  gates: %{"exec" => :approve},
  system_prompt: "You are a QA agent..."
}
```

**Container lifecycle:**
- Agent is created → its container starts (built from the type's Dockerfile)
- Agent exec's into ITS container, not the shared workspace container
- Multiple agents of the same type share an image (built once, reused)
- Agent is stopped → container stops. Agent is removed → container is removed.
- The code volume is shared across all agent containers — they all see the same files

**Presets with computers:**

| Preset | Computer | Tools | Use case |
|--------|----------|-------|----------|
| Setup | Full dev env (Ruby/Node/Python, Docker CLI, git) | Workspace, Agents | Bootstrap projects |
| Developer | Project-specific (from project's Dockerfile) | Workspace, Agents | Write code |
| QA | Playwright + Chromium | Workspace, Browser, Agents | Visual testing |
| Code Review | Alpine + linters only | Workspace (read-only) | Review without modifying |
| Data | Python + pandas + psql | Workspace, Database | Data analysis |

**The key insight:** the computer and the tools are two sides of the same
capability. The computer is what's installed (raw executables, libraries,
runtimes). The tools are the structured API the agent uses to interact
(MCP tool calls). A QA agent needs Chromium installed (computer) AND the
screenshot tool (MCP). One without the other is useless.

**Shared vs isolated:**
- All agent containers mount the same code volume (`${CODE_VOLUME}:/workspace`)
- Service containers (postgres, redis, dev server) are shared infrastructure
- Agent containers are per-type — isolated environments for different jobs
- The compose stack grows: workspace, dev, postgres, redis + qa-agent, data-agent, etc.

### Implementation order

1. Add `title` and `description` to `__tool_server__/0` in each toolkit module
2. Create `BoomLooper.Tools.Registry` — lists all available servers
3. Update "New Agent" UI to show tool selection
4. Store selected tool servers on the agent record
5. `ToolConfig.resolve_servers` builds MCP server map from selection
6. **Agent containers** — each agent type gets its own container from a Dockerfile/image
7. Agent exec routes to the agent's own container (not the shared workspace container)
8. Presets — saved name + tool selection + computer + gates, per-project or global
9. Per-tool granularity (phase 2)
10. Gate policies per agent type (see `plans/human-gates.md`)
