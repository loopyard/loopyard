# Source Adapters: Where Code Comes From

The `Source` behaviour (`lib/boom_looper/source.ex`) defines how a project's code is materialized. Each project carries a `source_type` (`:local` or `:github`). `Source.for_project/1` dispatches to the right adapter.

**Local** (`Source.Local`): the user already has the code on their machine. `ProjectRegistry.add(path)` registers it. Files live in a Docker volume; Mutagen syncs the volume with a host-side git worktree. Git is a host-side human concern — agents edit files, humans commit/push.

**GitHub** (future): OAuth, clone via API, PR integration. The stub forwards to `add_from_url` today.

## Rules

- The orchestration layer (`ServiceManager`, `ChatAgent`, `ProjectRegistry`) never calls adapter internals directly — only through `Source.for_project(project).callback(...)`.
- Adapter-specific code lives under `lib/boom_looper/source/local/` (or `github/`). Nothing about mutagen, host worktrees, or local-path handling leaks into orchestration modules.
- Both adapters coexist at runtime — dispatch is per-project based on `source_type`.
- **Eval runner clones with host git then registers as Local.** The clone is eval scaffolding, not a Source adapter concern. Local assumes the user already has the code.
