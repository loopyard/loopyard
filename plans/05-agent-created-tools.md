---
title: Agent-Created Tools
status: planned
depends_on: [02-docker-integration]
---

# Agent-Created Tools

Agents should be able to define new tools at runtime. If an agent needs a capability that doesn't exist yet, it writes the Elixir module and registers it.

## How it could work

1. Agent writes a tool module (Elixir source) inside its workspace
2. Agent calls a meta-tool like `Tools.register("path/to/my_tool.ex")`
3. Hive compiles and loads the module in a sandboxed scope
4. New tool becomes available to the agent immediately

## Safety

- Tools run on the Hive host, so they need to be sandboxed
- Option A: Only allow tools that call Docker exec (tools are just wrappers around container commands)
- Option B: Compile with restricted imports (no System, no File, no Port — only approved modules)
- Option C: Run agent-created tools inside the container too (via Code.eval_string over docker exec)

Option A is simplest and safest — agent-created tools are just named wrappers around container commands.

## Acceptance criteria

- [ ] Agent can write a tool module
- [ ] Agent can register the tool at runtime
- [ ] Tool becomes callable in the same session
- [ ] Tool shows up in the UI panel
- [ ] Safety: tool can't access host filesystem or network directly
