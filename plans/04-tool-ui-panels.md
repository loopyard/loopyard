---
title: Tool UI Panels
status: planned
depends_on: [02-docker-integration, 03-browser-tools]
---

# Tool UI Panels

Each tool instance the agent creates becomes a clickable item in the sidebar. Clicking it opens a live panel showing what the tool is doing.

## The idea

When an agent spawns a container, starts a browser, or runs a server — those show up under the agent in the sidebar. Humans can click to observe:

- **Container panel**: live log stream (stdout/stderr), maybe a file browser
- **Browser panel**: current URL, live screenshot (auto-refreshing), network request log
- **Server panel**: stdout/stderr log tail, port number, uptime, health status

## What to build

- Tool instance registry — track which tools each agent has active
- Sidebar: nested tree (agent → its tools)
- LiveView components for each tool type's panel
- PubSub streams from tool processes to panels
- Screenshot auto-refresh (poll or push on navigation)

## UI sketch

```
Sidebar:
  [+] New Agent
  ● Sharp Pulse          ← click for chat
    📦 Container         ← click for container logs
    🌐 Browser           ← click for screenshot + network
    🖥 Dev Server (3000) ← click for server logs
  ● Bold Mesa
    📦 Container
```

Main panel switches between chat view and tool panel based on what's selected.

## Acceptance criteria

- [ ] Active tools show under their agent in the sidebar
- [ ] Clicking a tool opens its panel in the main area
- [ ] Container panel shows live log output
- [ ] Browser panel shows current screenshot and URL
- [ ] Server panel shows log output and port
- [ ] Panels update in real-time via PubSub
- [ ] Tools cleaned up from sidebar when agent stops
