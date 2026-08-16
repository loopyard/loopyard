# Loopyard

> An open source multiplayer harness where teams and AI ship code together.

Point Loopyard at a git repo. It examines the codebase, writes a Dockerfile, spins up databases, starts the dev server, and hands you a working environment with Claude Code agents ready to write and run code inside it.

Everything is multiplayer. Multiple people can watch agents work, interact with them, and share terminal sessions. Open the same project on your phone and laptop, or have three developers watching one agent debug a failing test.

More at [loopyard.ai](https://loopyard.ai).

### Why this exists

Coding agents are at their best when you let them run: full autonomy, no permission prompt every thirty seconds. But an agent running unattended on your host has your whole machine — your SSH keys, your dotfiles, every other repo. Loopyard removes that tradeoff: agents work inside Docker containers with no access to the host, so you can turn the safety prompts off and let a harness run overnight. The blast radius is a container you can delete and rebuild, not your laptop.

The agent doesn't just write code inside that boundary; it builds the whole stack (Dockerfile, services, dev server, env vars) and execs into the container to work.

**What you get:**
- Zero-config project setup. Clone a repo, launch it, the agent figures out the rest.
- Full Docker stack: workspace, dev server, postgres, redis, whatever the project needs.
- Multiplayer. Every chat, terminal, and service log has its own URL, live on every device.
- Multiple agents per project, running at the same time — plus an operator agent that watches every workspace and dispatches work.
- Questions that wait for you: agents park decisions as durable cards you answer from the chat, the For You rail, or the `/review` deck.
- SSH into any container: `ssh -p 2222 container-name@localhost`.
- Containers and conversations persist across server restarts.

## Getting started

Runs on macOS and Linux. You need [Elixir](https://elixir-lang.org) 1.19+,
Node.js, [Mutagen](https://mutagen.io) (host-to-volume file sync), and a
running Docker daemon — [Docker Desktop](https://docker.com),
[Colima](https://github.com/abiosoft/colima), or OrbStack on macOS; Docker
Engine on Linux. Docker isn't a dependency so much as the substrate: every
workspace, agent, and dev server is a container, so nothing works until
`docker version` succeeds.

On macOS, `mix loopyard.setup` installs the tool dependencies for you via
[Homebrew](https://brew.sh) (`brew bundle`). On Linux, install
elixir/node/mutagen/fswatch with your package manager first; setup detects
the missing brew and takes it from there.

```bash
git clone https://github.com/loopyard/loopyard.git
cd loopyard
mix loopyard.setup
mix loopyard.server
```

Then open http://localhost:4000 and **connect Claude** — the dashboard leads
with it. Agents build everything else (the Dockerfile, the services, the dev
server), so none of that can start until Claude can authenticate. The one
command it gives you runs on your machine, opens a browser to authorize, and
pushes a 1-year token back:

```bash
curl -fsS "http://localhost:4000/workstations/<you>/claude/setup.sh?token=..." | sh
```

From there, `/workstations/<you>` is where the rest of your tools connect —
GitHub, Fly, Codex — the same way. Loopyard is self-hosted, so credentials are
pushed *up* from your machine rather than read off your disk; that's also what
makes it work when the server is on a different box than your laptop.

Launch a project from any directory:

```bash
open "http://localhost:4000/launch/SECRET?path=$(pwd)"
```

The actual URL is printed when the server starts.

## How it works

1. Launch a project. Point Loopyard at any git repo.
2. The agent reads the repo and detects the stack: language, framework, databases, services. One agent, no separate setup mode.
3. It writes the Dockerfile and Docker Compose, then builds and runs everything.
4. Agents exec into the workspace container to write code, run tests, debug.
5. You watch, interact, collaborate. Every view is a live, multiplayer URL.

## Compared to

How Loopyard relates to other tools, one page per comparison:
[Claude Code CLI](https://loopyard.ai/vs/claude-code-cli),
[Claude Code Desktop](https://loopyard.ai/vs/claude-code-desktop),
[Commander](https://loopyard.ai/vs/commander),
[OpenCode](https://loopyard.ai/vs/opencode),
[Codex](https://loopyard.ai/vs/codex),
[Cursor](https://loopyard.ai/vs/cursor).

## License

[AGPL-3.0](LICENSE). Free to run, read, and change.

## Contributing

See [CLAUDE.md](CLAUDE.md) for code rules, architecture, and testing.

Claude Code skills for common workflows:
- `/new-feature` plan, test, build, integrate
- `/fix-bug` reproduce in a test first, then fix
- `/review-pr` check against project rules
- `/setup` get Loopyard running on a new machine

Every feature needs tests. Every bug fix starts with a failing test.
