---
title: Root Agent
status: thinking
depends_on: [02-docker-integration]
---

# Root Agent

The Root Agent runs on bare metal (or in the host sandbox). It's the only agent with access to the host machine. All other agents run inside Docker containers that Root created.

## What Root can do that others can't

- Edit Hive's own source code
- Build and push Docker images
- Create/destroy containers
- Manage the host filesystem
- Access Docker socket
- Bootstrap the entire system

## What Root CANNOT do

- Grant other agents host access
- Disable itself (only humans can toggle it)
- Run without explicit human authorization

## The hierarchy

```
Human (enables/disables Root)
  └── Root Agent (host access, edits Hive code, builds images)
       └── Container Agent 1 (full access inside its container)
       └── Container Agent 2 (full access inside its container)
       └── ...
```

## Human controls

- **Enable Root**: human clicks a button or sets an env var
- **Disable Root**: human clicks a button — Root stops, containers keep running
- **Root is off by default.** You opt in.

When Root is off:
- Agents can still be created (they just use existing container images)
- Agents can't modify Hive's code or infrastructure
- The system is "locked down" — running but not self-modifying

When Root is on:
- Root can update Dockerfiles, rebuild images, change Hive config
- Root can fix infrastructure issues (broken containers, missing deps)
- Root can respond to "the system needs to change" requests

## Why this matters

Right now (this conversation), I'm effectively a Root Agent stuck in a sandbox. I can edit code but can't run it. Once Docker integration works:

1. Human starts Hive on host
2. Human enables Root Agent
3. Root builds the base container image
4. Root creates first container agent
5. Human disables Root (optional — system is running)
6. Container agents do all the work
7. If something breaks at the infrastructure level, human re-enables Root

## Implementation

Root Agent is just a ChatAgent with `docker: false` (runs on host) and a flag marking it as root. The flag controls:
- Whether it appears in the UI with a special indicator
- Whether it has access to host-level tools (Docker socket, filesystem)
- Whether it can be toggled by humans only

```elixir
# In ChatAgent init
root = Keyword.get(opts, :root, false)

tools = if root do
  [Hive.Tools.Agents, Hive.Tools.Container, Hive.Tools.Host]
else
  [Hive.Tools.Agents, Hive.Tools.Container]
end
```

`Hive.Tools.Host` would only be available to root — direct host filesystem access, Docker socket, Hive config changes.

## Open questions

- Should there be only one Root Agent, or can there be multiple?
- Should Root have a budget/rate limit to prevent runaway infrastructure changes?
- How does Root auth work in prod? (env var? admin UI? API key?)

## Host binary punchthrough

Root Agent (or a curated set of host tools) could punch through to host
binaries for deployment and ops workflows:

- `fly deploy` — deploy to Fly.io from the host workstation
- `gh pr create` — create PRs using the host's GitHub auth
- `git push` — push from the host's git config with SSH keys
- `aws`, `gcloud`, `kubectl` — cloud CLIs that need host credentials

These are NOT container tools — they run on the host because they need
the host's credentials, SSH keys, and CLI configs. They'd be a
`Tools.Host` MCP server available only to Root agents.

**Safety:** Each host binary is explicitly registered (not a generic
"run anything on host" escape hatch). The tool wraps a specific binary
with specific allowed arguments. Gates can require approval per-call.

**Alternative:** Run these in a privileged container with host credential
mounts. This keeps the Docker boundary intact while still accessing
host secrets. Tradeoff: more Docker complexity vs cleaner security model.
