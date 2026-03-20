# Spec: Projects & Branches

## Concept

Replace the flat "workspace" concept with **Projects** and **Branches**.

- **Project** = a git repo. Owns the config (Dockerfile, dev command, services, env vars).
- **Branch** = a running instance of that project on a specific git branch. Each gets its own directory (via `git worktree`), its own set of containers, its own port.

There is no "checkout" or "switch branch." You add branches and remove them. Every active branch is always running simultaneously. It's like browser tabs for branches.

```
Project: beautifulruby/server
  ├── main              → running on port 3400
  ├── stripe-billing    → running on port 3401
  └── fix-css-bug       → running on port 3402
```

## How It Works

### Projects

A Project is created by pointing at a git repo (cloned locally or via GitHub). The project stores its config — Dockerfile, dev command, services, env vars — once. All branches share this config.

Non-git directories are fine too. They're just a project with one permanent branch and no "add branch" option. But git is assumed for v1 since that's the real use case.

### Branches

Each branch is backed by `git worktree`. Adding a branch runs `git worktree add`, which creates a new directory that shares the same `.git` database as the main repo. No copying, no re-cloning. Each worktree is a different branch checked out in its own directory.

The default branch (usually `main`) is the original clone directory. Additional branches are worktrees in a sibling `.worktrees/` directory.

Each branch gets:
- Its own worktree directory (bind-mounted into containers)
- Its own ops container (for agent exec)
- Its own dev server container (on its own port)
- Its own service containers (postgres, redis, etc. — no shared databases between branches to avoid migration conflicts)

The Docker image is shared across all branches in a project (same Dockerfile). `rebuild` rebuilds once and restarts all branches.

### Ports

Auto-assigned from a range. Users don't pick ports. The `PORT` env var is set for each branch's dev server.

### Adding a Branch

1. User clicks "New Branch" on a project
2. Enters branch name (e.g. "stripe-billing"), optionally picks a base branch
3. System runs `git worktree add`, spins up containers, assigns a port
4. Branch appears in the UI as running

### Removing a Branch

Stop containers, `git worktree remove`, free the port. The primary branch (main) can't be removed — it's the original clone directory.

## UI

The project list shows projects with their branches underneath:

```
beautifulruby/server
  ├── main           ● running   :3400   [Open] [Stop]
  ├── stripe-billing ● running   :3401   [Open] [Stop]
  └── fix-css-bug    ○ stopped           [Start] [Remove]

[+ Add Project]
```

Opening a branch shows its agents, services, and dev server status.

## Container Model

The container is a dev workstation, not a deploy target. It's the laptop.

- **Image** = the OS + toolchain (Ruby, Node, git, gh, build tools). Thin — just system deps and language runtimes.
- **Volume (bind mount)** = the project/worktree directory. Same as `~/Projects/whatever` on a laptop.
- **Dependency install** (`bundle install`, `npm install`) = happens inside the running container after boot, against the volume-mounted code. Not baked into the image. Just like you'd do on a real workstation.

### Key Lessons from Setup

- The platform injects `BUNDLE_FROZEN=true` by default for Ruby — override to `false`.
- The platform mounts a volume at `/root/.cache` that shadows anything the Dockerfile puts there.
- The platform overrides Dockerfile `ENV` vars at runtime — use `set_env_vars` to control bundle config, not the Dockerfile.
- For Ruby projects, `vendor/bundle` on the bind mount is the reliable gem location.
- Always `rm -f tmp/pids/server.pid` before starting Rails — stale PID files prevent boot.
- Tailwind CSS `watch` needs `--poll` in Docker containers.

## Agents

Agents are associated with a branch, not just a project. When spawned, an agent targets a specific branch and execs into that branch's ops container.

## Migration

If `.hive/workspace.json` exists, auto-migrate to the new project config format on first load.
