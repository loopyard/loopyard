defmodule Loopyard.Resources do
  @moduledoc """
  Explicit resource ownership: every tracked resource belongs to some
  Elixir pid and is released when that pid goes DOWN.

  Move #7b in `plans/archive/coordination-hardening.md`.

  ## The bug class this kills

  Orphan resources that survive their owner — port bindings outliving
  a dead workspace, streaming Tasks outliving a dead agent, CLI
  subprocesses outliving a dead GenServer. Today each resource has
  its own ad-hoc cleanup: a `Process.link`, a `trap_exit`, a
  `terminate/2` callback, an explicit `release_workspace/1` call
  somewhere. Easy to miss one — the release doesn't run, the resource
  leaks, nobody notices until Docker is out of networks.

  With this module, an owner calls `track/4` when it allocates the
  resource. A supervised janitor (`Loopyard.Resources.Janitor`)
  monitors the owner pid. When the pid goes DOWN for any reason —
  normal exit, crash, `kill -9`, supervisor teardown — the janitor
  invokes the release function for every resource the pid owned.
  No `terminate/2` required; no callback to forget.

  ## API shape

      Loopyard.Resources.track(
        owner_pid,
        :port_binding,
        {workspace_id, service, container_port},
        fn -> Loopyard.PortRegistry.release(ws, svc, cport) end
      )

  `track/4` is idempotent — calling it twice with the same `{kind,
  id}` pair is a no-op as long as the owner hasn't changed. Changing
  the owner for an already-tracked resource is not supported and
  returns `{:error, :already_tracked}` so we don't silently lose the
  original owner's cleanup.

  ## What's in-scope vs. out-of-scope

  ### In scope (tracked via this module)

    * **PortRegistry bindings** — owned by the workspace supervisor
      (`WorkspaceGroup`) pid. When the supervisor dies for any
      reason, ports auto-release. Eliminates the "forgot to call
      `release_workspace/1`" bug class.

  ### Out of scope (explicit non-migrations — documented here so
  nobody adds them later without thinking)

    * **Docker containers.** Already owned by the `compose up` /
      `compose down` lifecycle. Tracking via this module would be a
      second destructor racing with compose; worse than no tracking.
      Containers die via `ServiceManager.terminate/2` +
      `Workspace.Destructor.destroy/1`.

    * **CLI subprocesses owned by ChatAgent.** The `claude_code` SDK
      opens a Port that's linked to the ChatAgent GenServer. Port is
      closed automatically when the GenServer exits. No orphaning
      possible via the BEAM's Port-link semantics.

    * **Mutagen sync sessions (SyncMonitor).** Design says the
      session OUTLIVES a GenServer restart — on `terminate/2` the
      session stays alive so the next `init/1` adopts it by name.
      Tracking under the SyncMonitor pid would break that design
      (janitor releases on every DOWN, including hot-reload /
      `:one_for_all` sibling-crash restarts). `SyncMonitor` handles
      its own destructor via the explicit
      `prepare_for_removal/1` → `terminate/2` path. Revisit if the
      "session survives crashes" policy ever changes.

    * **Short-lived `Port.open` calls** (Docker CLI wrappers,
      VolumeCloner, EvalRunner, Terminal). Each Port is
      automatically linked to the opening process and dies with it.
      The resource IS the process-local lifetime here; no tracking
      needed.

  ## Telemetry

    * `[:loopyard, :resources, :tracked]` — one per `track/4`
      call (excluding idempotent re-tracks). Meta: `%{kind, owner}`.
    * `[:loopyard, :resources, :released]` — one per release
      (both owner-DOWN and explicit `release/2`). Meta: `%{kind,
      reason: :owner_down | :explicit | :release_fn_error}`.
    * `[:loopyard, :resources, :orphan]` — fired if the janitor
      discovers a tracked resource whose owner was dead BEFORE the
      monitor attached (shouldn't happen — we monitor before insert
      — but belt-and-suspenders). Meta: `%{kind, owner}`.
  """

  alias Loopyard.Resources.Janitor

  @type kind :: atom()
  @type id :: term()
  @type release_fn :: (-> any()) | nil

  @doc """
  Track a resource under an owner pid.

  The janitor monitors `owner_pid` (if not already monitored for
  another resource) and invokes `release_fn` when the pid goes DOWN.
  If `release_fn` is `nil`, the janitor logs the release but does
  nothing else — useful for pure bookkeeping resources.

  Idempotent: re-tracking the same `{kind, id}` under the same pid
  is a no-op (returns `:ok`). Re-tracking under a DIFFERENT pid
  returns `{:error, :already_tracked}` — the caller is almost
  certainly buggy.

  Returns `:ok` on success.
  """
  @spec track(pid(), kind(), id(), release_fn()) :: :ok | {:error, :already_tracked}
  def track(owner_pid, kind, id, release_fn \\ nil)
      when is_pid(owner_pid) and is_atom(kind) do
    Janitor.track(owner_pid, kind, id, release_fn)
  end

  @doc """
  Manually release a resource. Invokes the recorded release_fn and
  removes the entry. Safe to call whether or not the owner is alive
  — explicit cleanup paths use this so the janitor doesn't later
  double-release on DOWN.

  Returns `:ok` whether the resource existed or not.
  """
  @spec release(kind(), id()) :: :ok
  def release(kind, id) when is_atom(kind) do
    Janitor.release(kind, id)
  end

  @doc """
  List every resource tracked under the given owner pid.

  Returns a list of `%{kind, id, owner}` maps, newest-first.
  """
  @spec list_for_owner(pid()) :: [map()]
  def list_for_owner(owner_pid) when is_pid(owner_pid) do
    Janitor.list_for_owner(owner_pid)
  end

  @doc """
  List every tracked resource across all owners.

  Returns a list of `%{kind, id, owner, owner_alive?}` maps. Used
  by the `/system/orphans` LV to surface any resource whose owner
  has died (shouldn't happen post-janitor, but the invariant is
  cheap to surface).
  """
  @spec all() :: [map()]
  def all do
    Janitor.all()
  end
end
