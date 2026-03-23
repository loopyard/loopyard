# Boom Looper

**AI agents that set up and run your entire dev environment.** Point Boom Looper at a git repo — it examines the codebase, writes a Dockerfile, spins up databases, starts the dev server, and hands you a working environment with Claude Code agents ready to write and run code inside it.

Everything is multiplayer. Multiple people can watch agents work, interact with them, and use the same terminal sessions — simultaneously, in real-time. Open the same project on your phone and laptop, or have three developers watching the same agent debug a failing test.

### Why this exists

Running Claude Code locally is great, but it runs on your host and you manage the environment yourself. Boom Looper gives each project a **containerized workspace** — isolated, reproducible, and sharable. The agent doesn't just write code, it builds the entire stack: Dockerfile, services, dev server, environment variables. Then it execs into that container to work.

**What you get:**
- **Zero-config project setup** — clone a repo, launch it, the Setup agent figures out what to install and run
- **Full Docker stack** — workspace container, dev server, postgres, redis, whatever the project needs
- **Multiplayer** — every chat, terminal, and service log has its own URL. Open in another tab, send to a teammate, or pull up on your phone
- **Multiple agents** — run a Setup agent, a Feature agent, and a Debug agent on the same project simultaneously
- **SSH into any container** — `ssh -p 2222 container-name@localhost` drops you into a shared terminal session
- **Work from any device** — start a task on your laptop, check progress from your phone on the couch, pick it back up on your desktop. Every device sees the same live state — no syncing, no context lost
- **Persistent containers** — restart the server, containers keep running. Pick up where you left off

## Getting started

macOS only. Requires [Homebrew](https://brew.sh).

```bash
git clone https://github.com/boomlooper/boomlooper.git
cd boomlooper
bin/setup
```

This installs Elixir, Docker Desktop, and Claude Code CLI via Homebrew, then builds the app.

Start the server:

```bash
mix phx.server
```

Launch from any project directory:

```bash
# The actual URL with secret is printed when the server starts
open "http://localhost:4000/launch/SECRET?path=$(pwd)"
```

The Setup agent will examine the project, build a Docker environment, and start everything. Watch it work in real-time.

## How it works

1. **Launch a project** — point Boom Looper at any git repo
2. **Setup agent** auto-detects the stack — language, framework, databases, services
3. **Docker Compose** builds and runs everything — workspace container, dev server, databases
4. **Agents exec into the workspace container** to write code, run tests, debug issues
5. **You watch, interact, and collaborate** — every view is live and multiplayer

## Compared to

### Claude Code CLI

Claude Code runs on your host machine. It's powerful but:
- No containerization — installs and changes happen on your actual system
- Single user — no multiplayer, no sharing sessions
- No infrastructure management — you set up Docker, databases, etc. yourself
- One agent at a time

Boom Looper wraps Claude Code in a containerized workspace with multiplayer. The agent gets the same Claude Code capabilities but in an isolated environment it built itself.

### [Commander](https://thecommander.app)

Commander provides a GUI for managing Claude Code sessions. Boom Looper goes further:
- **Builds the dev environment**, not just manages the AI session — Dockerfile, Docker Compose, services, dev server
- **Multiplayer** — Commander is single-user. Boom Looper lets a team watch and interact with agents simultaneously
- **Container isolation** — every project gets its own Docker stack. Nothing touches your host
- **SSH access** — drop into any container from your terminal. Commander is browser-only
- **Multiple agents per project** — run Setup, Feature, and Debug agents simultaneously on the same codebase

## Contributing

See [CLAUDE.md](CLAUDE.md) for code rules, architecture, and testing requirements. Every feature needs tests. Every bug fix starts with a failing test. No exceptions.
