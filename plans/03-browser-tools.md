---
title: Browser Tools
status: planned
depends_on: [02-docker-integration]
---

# Browser Tools

Headless browser controlled by the agent through Elixir tool modules. The browser runs on the Hive host (not in Docker) and can reach web servers inside the agent's container.

## What to build

- `Hive.Tools.Browser` tool module
- Browser process management (spawn, reuse, cleanup per agent)
- Tools: visit, click, fill, screenshot, html, network activity
- Screenshots returned as base64 for inline display in chat

## Library choice

| Option | Pros | Cons |
|--------|------|------|
| Wallaby | Elixir-native, good API | ChromeDriver only, less browser features |
| Playwright (via port) | Full browser support, network interception | Needs Node.js, subprocess management |

Leaning Wallaby for simplicity. Can swap later.

## How it connects

```
Agent calls Browser.visit("http://localhost:{port}")
  → Hive executes in Wallaby/Playwright process
  → Browser connects to container's mapped port
  → Returns page content/screenshot to agent
```

## Acceptance criteria

- [ ] Agent can navigate to a URL
- [ ] Agent can take a screenshot and see it
- [ ] Agent can click elements and fill forms
- [ ] Agent can read page HTML/text
- [ ] Browser connects to web servers in agent containers
- [ ] Browser cleaned up when agent stops
