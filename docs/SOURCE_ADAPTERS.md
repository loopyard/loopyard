# Source Adapters: Where Code Comes From

The `Source` behaviour (`lib/loopyard/source.ex`) defines how a project's code is materialized. Each project carries a `source_type` (`:local` or `:github`). `Source.for_project/1` dispatches to the right adapter; for legacy records missing `source_type` it falls back to `Source.GitHub` when the project has a bare `:git_url`, and to `Source.Local` otherwise.

**Canonical-backed projects bypass the Source saga.** The default new-project path (`Loopyard.Onboarding.create_project/2` / `fork/3`, backed by `Loopyard.CanonicalRepo`) materializes the workspace volume synchronously in a transient git container and registers the workspace `:ready` directly (`Setup.ready_setup_field/0`) — no `Workspace.Setup` saga runs. The lifecycle below applies to `WorkspaceRegistry.add_workspace/2` workspaces (Local projects, and legacy `add_from_url` GitHub projects).

**Local** (`Source.Local`): the user already has the code on their machine. `ProjectRegistry.add(path)` registers it. Files live in a Docker volume; Mutagen syncs the volume with a host-side git worktree. Git is a host-side human concern — agents edit files, humans commit/push. Its `git_*` callbacks run host git against the synced worktree.

**GitHub** (future): OAuth, clone via API, PR integration. The stub forwards to `add_from_url` today. **Git, though, is wired up:** a GitHub workspace has NO host worktree — `.git` lives only inside the code volume — so its `git_*` callbacks hand `Loopyard.Git` a *runner* that execs `git -C /workspace` inside the workspace container (`safe.directory` set per-call because volume files are root-owned). `Loopyard.Git`'s functions take a `target` that is either a host path (binary) or a runner fn, so the same parsing serves both. This is what makes the git viewer (`/volumes/:vol/git`) work for volume-only workspaces.

## Rules

- The orchestration layer (`ServiceManager`, `ChatAgent`, `ProjectRegistry`) never calls adapter internals directly — only through `Source.for_project(project).callback(...)`.
- Adapter-specific code lives under `lib/loopyard/source/local/` (or `github/`). Nothing about mutagen, host worktrees, or local-path handling leaks into orchestration modules.
- Both adapters coexist at runtime — dispatch is per-project based on `source_type`.
- **Eval runner clones with host git then registers as Local.** The clone is eval scaffolding, not a Source adapter concern. Local assumes the user already has the code.

## Workspace setup lifecycle

`WorkspaceRegistry.add_workspace/2` returns immediately with `setup.phase: :pending` after running fast-path work (worktree + volume create + config copy). The slow part — populating the volume — runs asynchronously in `Loopyard.Workspace.Setup`.

**Phases** (PR1). The saga runs the three adapter phases in order — `Workspace.Setup.phases/0` is `[:worktree, :volume, :seeding]`, and the SetupProgress UI renders the step list in the same order:

1. `:pending` — fast-path done, async saga not started yet.
2. `:running` — saga task is alive.
3. `:worktree` — adapter's `do_create_worktree/1` is creating the source-of-truth tree (Local: host git worktree + `.loopyard` config copy).
4. `:volume` — adapter's `do_create_volume/1` is running `docker volume create` (idempotent).
5. `:seeding` — adapter's `do_seed_volume/3` callback is rsyncing source → volume.
6. `:ready` — terminal success.
7. `:failed` — terminal failure with structured error map. The `Failed` event's `phase` is the phase that failed, or `:unexpected_crash` when the saga task itself raised/exited outside a phase.

**Adapter contract:** every `Source` implementation must provide the three phase callbacks — `do_create_worktree(workspace)`, `do_create_volume(workspace)`, and `do_seed_volume(workspace, callback, opts)`. All idempotent — must tolerate re-runs (the Retry button), and seeding must be safe on a partially-seeded volume (no `--delete` or destructive flags). For Local, seeding rsyncs `worktree_path` → volume and writes a `.loopyard/.seeded` sentinel (so retries skip when already seeded). For GitHub today all three are no-ops because `add_from_url` clones synchronously; PR2 will route GitHub through the saga proper.

**Events:** all transitions broadcast on `Loopyard.Events.WorkspaceSetup` (per-workspace + global topics). Subscribers implement the `Subscriber` behaviour with explicit `on_setup_*` callbacks. See `lib/loopyard/events/workspace_setup.ex`.

**Restart recovery:** if the BEAM dies while a saga is `:running`, `Workspace.Setup.recover_on_boot/0` (called from `Application.start`) marks the workspace `:failed` with `error.code: :interrupted_by_restart`. The user clicks Retry; we never auto-resume.

**Cancellation:** `Workspace.Destructor.destroy/1` calls `Workspace.Setup.cancel/1` first so the rsync ephemeral container doesn't keep writing to a volume we're about to delete.
