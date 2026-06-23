# Source Adapters: Where Code Comes From

The `Source` behaviour (`lib/loopyard/source.ex`) defines how a project's code is materialized. Each project carries a `source_type` (`:local` or `:github`). `Source.for_project/1` dispatches to the right adapter.

**Local** (`Source.Local`): the user already has the code on their machine. `ProjectRegistry.add(path)` registers it. Files live in a Docker volume; Mutagen syncs the volume with a host-side git worktree. Git is a host-side human concern — agents edit files, humans commit/push. Its `git_*` callbacks run host git against the synced worktree.

**GitHub** (future): OAuth, clone via API, PR integration. The stub forwards to `add_from_url` today. **Git, though, is wired up:** a GitHub workspace has NO host worktree — `.git` lives only inside the code volume — so its `git_*` callbacks hand `Loopyard.Git` a *runner* that execs `git -C /workspace` inside the workspace container (`safe.directory` set per-call because volume files are root-owned). `Loopyard.Git`'s functions take a `target` that is either a host path (binary) or a runner fn, so the same parsing serves both. This is what makes the git viewer (`/volumes/:vol/git`) work for volume-only workspaces.

## Rules

- The orchestration layer (`ServiceManager`, `ChatAgent`, `ProjectRegistry`) never calls adapter internals directly — only through `Source.for_project(project).callback(...)`.
- Adapter-specific code lives under `lib/loopyard/source/local/` (or `github/`). Nothing about mutagen, host worktrees, or local-path handling leaks into orchestration modules.
- Both adapters coexist at runtime — dispatch is per-project based on `source_type`.
- **Eval runner clones with host git then registers as Local.** The clone is eval scaffolding, not a Source adapter concern. Local assumes the user already has the code.

## Workspace setup lifecycle

`WorkspaceRegistry.add_workspace/2` returns immediately with `setup.phase: :pending` after running fast-path work (worktree + volume create + config copy). The slow part — populating the volume — runs asynchronously in `Loopyard.Workspace.Setup`.

**Phases** (PR1):

1. `:pending` — fast-path done, async saga not started yet.
2. `:running` — saga task is alive.
3. `:seeding` — adapter's `do_seed_volume/3` callback is rsyncing source → volume.
4. `:ready` — terminal success.
5. `:failed` — terminal failure with structured error map.

**Adapter contract:** every `Source` implementation must provide `do_seed_volume(workspace, callback, opts)`. Idempotent — must be safe to re-run on a partially-seeded volume (no `--delete` or destructive flags). For Local, this rsyncs `worktree_path` → volume and writes a `.loopyard/.seeded` sentinel (so retries skip when already seeded). For GitHub today this is a no-op because `add_from_url` clones synchronously; PR2 will route GitHub through the saga proper.

**Events:** all transitions broadcast on `Loopyard.Events.WorkspaceSetup` (per-workspace + global topics). Subscribers implement the `Subscriber` behaviour with explicit `on_setup_*` callbacks. See `lib/loopyard/events/workspace_setup.ex`.

**Restart recovery:** if the BEAM dies while a saga is `:running`, `Workspace.Setup.recover_on_boot/0` (called from `Application.start`) marks the workspace `:failed` with `error.code: :interrupted_by_restart`. The user clicks Retry; we never auto-resume.

**Cancellation:** `Workspace.Destructor.destroy/1` calls `Workspace.Setup.cancel/1` first so the rsync ephemeral container doesn't keep writing to a volume we're about to delete.
