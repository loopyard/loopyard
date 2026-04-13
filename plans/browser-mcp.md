# Browser MCP: screenshot & navigation tool for agents

## Problem

After an agent builds a feature, the user has to manually navigate to it in their browser to see it. On mobile this is especially painful — Docker port mappings don't work, and you can't easily switch between the chat and a browser tab.

The `app_url` tool helps (gives a clickable link) but you still leave the chat to see the result. Screenshots inline in the chat would close the loop entirely.

## Design

A dedicated Docker container running Playwright + an MCP server. The agent talks to it like any other tool server (`boom-looper-browser`), separate from `boom-looper-container`.

### Architecture

```
Agent
  ├── boom-looper-container (exec, write_file, docker_compose, ...)
  ├── boom-looper-browser   (screenshot, navigate, ...)
  └── boom-looper-agents    (spawn, send_message, ...)
```

The browser container lives in the workspace's compose stack:

```yaml
services:
  browser:
    image: bl-browser:latest  # Playwright + MCP server
    depends_on: [dev]
    # No ports exposed — only agents talk to it via MCP
```

It can reach `dev` on the internal Docker network (`http://dev:3000/...`) — no port mapping, no host/LAN issues.

### MCP Tools

**`screenshot`** — render a page, return a PNG
```
screenshot(url: "/users/1")
screenshot(url: "/users/1", width: 390, height: 844)  # mobile viewport
screenshot(url: "/users/1", cookies: [{name: "_session", value: "abc"}])
screenshot(url: "/users/1", full_page: true)
```

**`navigate`** — multi-step flow (login → navigate → screenshot)
```
navigate(steps: [
  {goto: "http://dev:3000/login"},
  {fill: "#email", value: "admin@test.com"},
  {fill: "#password", value: "password"},
  {click: "[type=submit]"},
  {wait: "networkidle"},
  {goto: "http://dev:3000/users/1"},
  {screenshot: true}
])
```

The agent writes the steps by reasoning about the app's auth flow from the code. No saved cookies — build state fresh each time (fast, never stale).

**`pdf`** — render a page as PDF (useful for reports, invoices)

### How the agent uses it

1. Agent builds a feature (writes code, runs migrations, starts dev server)
2. Agent reasons about the route: "the new user profile is at /users/1"
3. Agent calls `screenshot(url: "/users/1")`
4. Browser container renders the page, returns the PNG
5. Chat shows the screenshot inline — user sees the result without leaving the conversation

For authenticated pages:
1. Agent reads `db/seeds.rb`, finds test user credentials
2. Agent calls `navigate` with login steps + final screenshot
3. Single tool call, sub-2-second execution

### Chat rendering

Screenshots come back as base64 PNG. The chat message renderer shows them as `<img>` tags inline. The agent's response looks like:

> Here's the user profile page:
> [inline screenshot image]
> 
> The sidebar navigation and avatar are working. Want me to adjust the layout?

### Implementation plan

1. **Browser container image** — Dockerfile: Node + Playwright + Chromium + MCP server script
2. **MCP server** — small Node.js or Python script that implements the MCP protocol, handles `screenshot` and `navigate` tool calls
3. **Compose integration** — add `browser` service to the agent-written docker-compose.yml (or add it automatically in `process_agent_compose`)
4. **Chat image rendering** — extend message renderer to display base64 images inline
5. **Agent prompt** — teach agents when to use browser tools vs container tools

### What NOT to do

- Don't save cookies/sessions — they go stale. Build state fresh each time.
- Don't drive the browser interactively like integration tests — one-shot render, screenshot, done.
- Don't run the browser on the host — keep it in Docker so it works everywhere.
- Don't make it heavy — Chromium binary is ~130MB but it's cached in the container image. Each screenshot is sub-second.

### Mobile bonus

Screenshots solve mobile completely. You can't click `localhost:32794` on your phone, but you CAN see a screenshot in the chat. The agent builds, screenshots, you review — all in the same chat, on any device.

### Future: BoomLooper as proxy

An even better mobile story: BoomLooper proxies the dev server. You browse `boomlooper.local:4000/proxy/dev/users/1` and BoomLooper forwards to `dev:3000/users/1` inside Docker. Same host, same port, works from any device. The proxy can inject cookies, capture HAR files, and the agent can observe your browsing session to understand what you're looking at.

This is a bigger architectural change but builds naturally on top of the browser container — the proxy would reuse the same Playwright instance for cookie management.
