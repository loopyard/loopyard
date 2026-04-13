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

### Live stream + agent snapshots: two views of one browser

The browser session is shared between the human and the agent, but
they see it differently:

**Human sees: live video feed in the chat.**
Chrome's `Page.startScreencast` (CDP) sends JPEG frames at 2-5 fps.
The MCP server streams them to BoomLooper via PubSub (same pattern as
docker compose build output). The chat LiveView renders each frame as
an `<img>` that updates in place — poor man's video, no WebRTC, no
ffmpeg, just rapid-fire JPEGs over the existing LiveView socket.

**Agent sees: nothing (it doesn't watch video).**
When the agent needs to "look" at the page, it grabs a single
screenshot from the same browser session — `Page.captureScreenshot`
via CDP. Instant, one frame, returned as tool result. The agent
reasons about the static image, decides what to do next, navigates,
and grabs another snapshot if needed.

**Both happen simultaneously.** Chrome supports screencast and
single-frame capture at the same time. Same browser, same session,
same cookies, same page state.

**Session lifecycle:**
1. Agent first calls a browser tool → browser session starts, stream begins
2. Human watches the live feed in the chat while the agent works
3. Agent grabs screenshots when it needs to "look"
4. Agent navigates (login, click, fill forms) — human sees it live
5. Agent finishes → stream stays alive (human can keep watching)
6. Session dies when agent conversation ends or explicit `browser.close()`

**Clips for replay:**
The stream is live — ephemeral. For replayable content, the agent can
call `browser.record(steps: [...])` which captures the navigation as a
WebM file (Playwright's built-in `video.path()`). The chat renders it
as a `<video>` element. The agent gets both: a video clip to reference
later and a final screenshot for its own reasoning.

### MCP tools (updated)

**`browser.open`** — start a browser session, begin streaming to chat
```
browser.open(url: "http://dev:3000/")
# Stream begins, human sees the page live
```

**`browser.navigate`** — navigate within the session
```
browser.navigate(url: "/users/1")
browser.navigate(actions: [
  {fill: "#email", value: "admin@test.com"},
  {click: "[type=submit]"}
])
```

**`browser.screenshot`** — grab a snapshot (for the agent's reasoning)
```
browser.screenshot()
# Returns base64 PNG — agent can "see" what the page looks like
```

**`browser.record`** — capture a navigation flow as a video clip
```
browser.record(steps: [
  {goto: "/login"},
  {fill: "#email", value: "admin@test.com"},
  {click: "[type=submit]"},
  {wait: "networkidle"},
  {goto: "/dashboard"}
])
# Returns a WebM clip + final screenshot
```

**`browser.close`** — end the session, stop the stream

### Streaming implementation

No video encoding needed. Just JPEGs:

```
Chrome (CDP Page.startScreencast)
  → JPEG frame every 200-500ms
  → MCP server receives frame
  → PubSub broadcast {:browser_frame, agent_id, jpeg_data}
  → LiveView handle_info updates an <img> tag's src
  → Human sees "video" in the chat
```

The LiveView renders it as:
```heex
<img src={"data:image/jpeg;base64,#{@browser_frame}"} class="rounded-lg" />
```

Updated on every PubSub message. At 5fps that's one assign update
every 200ms — well within LiveView's capacity.

### What NOT to do

- Don't save cookies/sessions across conversations — build auth state fresh each time.
- Don't use ffmpeg or WebRTC for the stream — JPEG frames over PubSub are simpler and good enough.
- Don't run the browser on the host — keep it in Docker.
- Don't make the agent "watch" the video stream — it grabs snapshots when it needs to look. Video is for humans.

### Mobile bonus

The live stream solves mobile completely. You can't click `localhost:32794`
on your phone, but you CAN watch the agent work in the chat — live video
of every page it navigates. Screenshots are stills you review after the
fact; the stream is watching it happen.

### Future: BoomLooper as proxy

An even better mobile story: BoomLooper proxies the dev server. You browse
`boomlooper.local:4000/proxy/dev/users/1` and BoomLooper forwards to
`dev:3000/users/1` inside Docker. Same host, same port, works from any
device. The proxy can inject cookies, capture HAR files, and the agent can
observe your browsing session to understand what you're looking at.

### Future: human takes over the browser

The stream is one-way today (watch only). But Chrome's CDP also accepts
input events — mouse clicks, keyboard input. A future version could let
the human click inside the streamed view to interact with the page,
effectively sharing a browser session with the agent. The agent navigates,
the human clicks a button, the agent sees the result.
