# Plan: Projects and Branches

## Summary

Replace the current "workspace" concept with **Projects** (git repos) and **Branches** (worktrees). Each branch gets its own set of running containers. Users think in repos and branches, not workspaces.

## Mental Model

```
Project: beautifulruby/server
  ├── main              → running on port 3400
  ├── stripe-billing    → running on port 3401
  └── fix-css-bug       → running on port 3402
```

- A **Project** is a git repo. It owns the config (Dockerfile, services, env vars, dev command) in `.hive/workspace.json`.
- A **Branch** is a git worktree of that project. Each gets its own containers (dev, postgres, redis, etc.) and its own set of agents.
- Default view shows the project with the `main` branch running.
- "Add branch" creates a `git worktree add`, spins up containers for that branch.
- "Remove branch" kills containers, runs `git worktree remove`.
- Every active branch is always running. No "checkout" — branches accumulate like browser tabs.

## Entry Points

### From local directory (existing)
```bash
open "http://localhost:4000/launch/SECRET?path=$(pwd)"
```
Detects the git repo root from the path. Creates a project pointing at it. The `main` branch is the directory itself.

### From GitHub (future)
```bash
open "http://localhost:4000/launch/SECRET?repo=github.com/user/repo"
```
Clones the repo to a managed directory, then same flow as above.

## Data Model

### Project
```elixir
%Project{
  id: "a866",                    # hash of repo root path
  name: "beautifulruby-server",  # from workspace.json or dir name
  path: "/Users/brad/Projects/beautifulruby/server",  # git repo root
  repo_url: "github.com/...",    # optional, for display
}
```

### Branch
```elixir
%Branch{
  id: "f3b2",                    # hash of worktree path
  project_id: "a866",            # parent project
  name: "main",                  # git branch name
  path: "/Users/brad/Projects/beautifulruby/server",  # worktree path (main = repo root)
  # OR for non-main branches:
  # path: "/Users/brad/Projects/beautifulruby/server/.worktrees/stripe-billing"
}
```

The branch `path` is what gets bind-mounted into containers. For `main`, it's the repo root. For other branches, it's the worktree directory.

### Config
`.hive/workspace.json` lives at the project level (repo root). All branches inherit it. When you rebuild one branch, it uses the same Dockerfile. The config is shared — it describes the project, not a branch.

## What Changes

### Rename: Workspace → Branch
- `BoomLooper.Workspace` module stays (it manages the config file) but the UI says "branch"
- `BoomLooper.WorkspaceRegistry` → `BoomLooper.ProjectRegistry`
- The registry stores projects, each with a list of active branches
- `workspace_id` concept maps to `branch_id` (hash of the worktree path)

### New Module: `BoomLooper.Git`
Thin wrapper around git CLI:
```elixir
Git.repo_root(path)              # git rev-parse --show-toplevel
Git.current_branch(path)         # git branch --show-current
Git.worktree_add(repo_path, branch_name)  # git worktree add
Git.worktree_remove(worktree_path)        # git worktree remove
Git.worktree_list(repo_path)     # git worktree list --porcelain
Git.is_repo?(path)               # checks if .git exists
```

### ProjectRegistry (replaces WorkspaceRegistry)
```elixir
ProjectRegistry.add(path)        # detects repo root, creates project + main branch
ProjectRegistry.list()           # all projects
ProjectRegistry.get(project_id)  # project with its branches
ProjectRegistry.add_branch(project_id, branch_name)  # git worktree add, register branch
ProjectRegistry.remove_branch(project_id, branch_id) # kill containers, git worktree remove
```

### Container Naming
Containers already use a workspace_id hash. This becomes the branch hash:
```
boom-looper-ws-{branch_id}           # workspace container (sleep infinity)
boom-looper-ws-{branch_id}-dev       # dev server container
boom-looper-svc-{branch_id}-postgres # stock service
```

Each branch gets fully independent containers. No port conflicts because ports are allocated per-branch (or dynamic).

### Port Allocation
Each branch needs different host ports to avoid conflicts. Options:
1. **Auto-assign** — each branch gets a random available port. Show in the UI.
2. **Offset** — main gets 3000, next branch gets 3001, etc.
3. **Let Docker pick** — use `-p 0:3000` and read the assigned port.

Option 3 is simplest. Docker picks a random host port, we read it with `docker port`.

### UI Changes

#### Home page (`/`)
```
Projects
  beautifulruby-server    3 branches running
  another-project         1 branch running
```

#### Project page (`/p/:project_id`)
```
beautifulruby-server
  [+ Add Branch]

  BRANCHES
    ● main              :3400    2 agents
    ● stripe-billing    :3401    1 agent
    ● fix-css-bug       :3402    0 agents
```

Click a branch → see its agents and services (current chat view).

#### Branch page (`/p/:project_id/b/:branch_id`)
Same as current `/w/:workspace_id` — agents list, services list, chat panel.

### Routes
```
/                                    # project list
/p/:project_id                       # project view (branches)
/p/:project_id/b/:branch_id         # branch view (agents + services)
/p/:project_id/b/:branch_id/new     # new agent for branch
/p/:project_id/b/:branch_id/chat/:id # agent chat
/p/:project_id/b/:branch_id/service/:name # service logs
```

### Launch flow
```bash
open "http://localhost:4000/launch/SECRET?path=$(pwd)"
```
1. `Git.repo_root(path)` to find the repo root
2. `ProjectRegistry.add(repo_root)` — creates project if new
3. `Git.current_branch(path)` — determines which branch
4. Ensure that branch is registered and running
5. Redirect to `/p/:project_id/b/:branch_id`
6. If no `.hive/workspace.json`, auto-spawn Setup agent

### Adding a branch
1. User clicks "+ Add Branch" on project page
2. Enters branch name (or picks from existing remote branches)
3. System runs `git worktree add .worktrees/{name} {name}`
4. If branch doesn't exist on remote, creates from current HEAD
5. Spins up containers using project config
6. Branch appears in the list, click to open

### Removing a branch
1. User clicks remove on a branch
2. System kills all containers for that branch
3. Stops all agents for that branch
4. Runs `git worktree remove {path}`
5. Branch disappears from list

### What stays the same
- `.hive/workspace.json` format — unchanged
- Docker image building — same, shared across branches (same Dockerfile)
- Service containers — same per-branch setup
- Agent lifecycle — same
- Chat UI — same
- MCP tools — same, they work with whatever branch the agent belongs to

## Implementation Order

1. **`BoomLooper.Git` module** — git CLI wrapper with tests
2. **`BoomLooper.ProjectRegistry`** — replaces WorkspaceRegistry, stores projects + branches
3. **Update launch flow** — detect repo root, register project + branch
4. **Update routes** — `/p/:project_id/b/:branch_id/...`
5. **Project list page** — shows projects with branch counts
6. **Project page** — shows branches with add/remove
7. **Branch page** — current workspace view, just re-routed
8. **Port allocation** — dynamic ports per branch
9. **Add branch flow** — git worktree add + container spin-up
10. **Remove branch flow** — container teardown + git worktree remove

## Supervisor Tree

Each branch is a supervision subtree that can be started/stopped as a unit:

```
BoomLooper.Supervisor
  ├── ProjectRegistry (ETS, always running)
  ├── BranchSupervisor (DynamicSupervisor — starts/stops branch subtrees)
  │   ├── Branch "main" (Supervisor, :one_for_all)
  │   │   ├── BranchManager (GenServer — owns state, coordinates lifecycle)
  │   │   ├── ServiceManager (GenServer — manages containers for this branch)
  │   │   ├── AgentSupervisor (DynamicSupervisor — agents for this branch)
  │   │   │   ├── ChatAgent "Setup"
  │   │   │   └── ChatAgent "dev-agent"
  │   │   └── ContainerMonitor (GenServer — watches container health, restarts)
  │   │
  │   └── Branch "stripe-billing" (Supervisor, :one_for_all)
  │       ├── BranchManager
  │       ├── ServiceManager
  │       ├── AgentSupervisor
  │       │   └── ChatAgent "feature-agent"
  │       └── ContainerMonitor
  │
  └── BoomLooperWeb.Endpoint
```

### Start a branch
```elixir
BranchSupervisor.start_branch(project_id, branch_name)
# → starts the branch Supervisor subtree
# → ServiceManager starts containers (workspace + dev + services)
# → Ready for agents
```

### Stop a branch
```elixir
BranchSupervisor.stop_branch(project_id, branch_id)
# → Supervisor.stop on the branch subtree
# → :one_for_all means everything shuts down together
# → ServiceManager terminate callback stops all Docker containers
# → All agents die with their supervisors
# → Branch stays in ProjectRegistry as :stopped
```

### Start/stop a project
Starting a project = start all its branches. Stopping = stop all branches. Just iterates.

### Why :one_for_all
If the ServiceManager crashes, agents can't exec. If the AgentSupervisor dies, there's nothing managing work. The branch is the unit — if any core piece dies, restart the whole branch cleanly.

### ContainerMonitor
Polls `docker ps` on a timer. If the workspace container dies, it restarts it. If the dev container dies, it marks it as stopped in the UI. Doesn't auto-restart dev — that's the agent's job (or the user's). The workspace container always comes back because it's the escape hatch.

### Terminate callbacks
```elixir
# ServiceManager
def terminate(_reason, state) do
  # Stop all containers for this branch
  Docker.stop_workspace_container(state.workspace_id)
  Enum.each(state.processes, fn p ->
    Docker.docker(["rm", "-f", process_container_name(state.workspace_id, p.name)])
  end)
  Enum.each(state.services, fn {name, _} ->
    Docker.docker(["rm", "-f", service_container_name(state.workspace_id, name)])
  end)
end
```

This means stopping the server (`ctrl+c`) cascades through the supervisor tree and cleans up all Docker containers. No orphans.

## Not in scope (future)
- GitHub clone flow (just need `gh repo clone` before the same flow)
- Non-git directories (works but no branch features)
- Shared Docker images across branches (optimization — each branch rebuilds for now)
- Branch merging (use GitHub PRs)
- Auto-detecting when branches are merged and cleaning up
