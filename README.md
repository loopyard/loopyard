# Loopyard

> An open-source multiplayer software factory where humans and AI ship code together.

Point Loopyard at a git repo. It examines the codebase, writes a Dockerfile, spins up databases, starts the dev server, and hands you a working environment with Claude Code agents ready to write and run code inside it.

Everything is multiplayer. Multiple people can watch agents work, interact with them, and share terminal sessions. Open the same project on your phone and laptop, or have three developers watching one agent debug a failing test.

### Why this exists

Claude Code runs on your host and you manage the dev environment yourself. Loopyard gives each project a containerized workspace that's isolated and shareable. The agent doesn't just write code; it builds the whole stack (Dockerfile, services, dev server, env vars) and then execs into the container to work.

**What you get:**
- Zero-config project setup. Clone a repo, launch it, the setup agent figures out the rest.
- Full Docker stack: workspace, dev server, postgres, redis, whatever the project needs.
- Multiplayer. Every chat, terminal, and service log has its own URL.
- Multiple agents per project, running at the same time.
- SSH into any container: `ssh -p 2222 container-name@localhost`.
- Same live state on every device. No syncing.
- Containers persist across server restarts.

## Getting started

macOS only. Requires [Homebrew](https://brew.sh).

```bash
git clone https://github.com/loopyard/loopyard.git
cd loopyard
mix loopyard.setup
mix loopyard.server
```

Launch from any project directory:

```bash
open "http://localhost:4000/launch/SECRET?path=$(pwd)"
```

The actual URL is printed when the server starts.

## How it works

1. Launch a project. Point Loopyard at any git repo.
2. Setup agent auto-detects the stack: language, framework, databases, services.
3. Docker Compose builds and runs everything.
4. Agents exec into the workspace container to write code, run tests, debug.
5. You watch, interact, collaborate. Every view is live.

## Compared to

### Claude Code CLI

Claude Code runs on your host. Installs and changes happen on your actual system, there's no multiplayer, and you manage Docker yourself. Loopyard wraps Claude Code in a containerized workspace the agent built itself, and lets a team share it.

### [Commander](https://thecommander.app)

Commander is a GUI for Claude Code sessions. Loopyard also builds the dev environment (Dockerfile, services, dev server), works for teams (Commander is single-user), supports SSH into any container, and runs multiple agents on the same project at once.

## Contributing

See [CLAUDE.md](CLAUDE.md) for code rules, architecture, and testing.

Claude Code skills for common workflows:
- `/new-feature` plan, test, build, integrate
- `/fix-bug` reproduce in a test first, then fix
- `/review-pr` check against project rules
- `/setup` get Loopyard running on a new machine

Every feature needs tests. Every bug fix starts with a failing test.
