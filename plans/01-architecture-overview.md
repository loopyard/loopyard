---
title: Architecture Overview
status: started
---

# Architecture Overview

Hive is an orchestrator for Claude Code agents. Agents are Claude sessions. Everything else — containers, browsers, servers — are tools the agent calls.

## Components

| Component | What | Where | Status |
|-----------|------|-------|--------|
| Hive | Control plane, chat UI, tool host | Elixir/Phoenix | Built |
| Agent | Claude Code SDK session | GenServer | Built |
| Tool modules | Agents, Container | Elixir modules | Built |
| Dev Environment | Sandboxed code execution | Docker container | Planned |
| Browser | Headless browser for testing | Elixir process | Planned |
| Tool UI panels | Live views into running tools | LiveView | Planned |

## Current State

```
Hive (Phoenix LiveView)
  └── ChatAgent (GenServer)
       └── ClaudeCode SDK session (NDJSON over subprocess)
       └── Tools: Hive.Tools.Agents, Hive.Tools.Container
```

## Target State

```
Hive (Phoenix LiveView)
  └── ChatAgent (GenServer)
       └── ClaudeCode SDK session (runs inside Docker container)
       └── Tools:
            ├── Agents — spawn/stop/message other agents
            ├── Container — create/exec/copy Docker containers
            ├── Browser — visit/click/screenshot headless browser
            └── DevServer — start/stop web servers in containers
  └── Tool UI Panels
       ├── Container panel — live logs, file browser
       ├── Browser panel — screenshot, URL, network activity
       └── Server panel — stdout/stderr, port, health
```
