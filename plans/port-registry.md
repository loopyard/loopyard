# Port Registry — v1 plan

The point of this work is **controlled exposure** — a user clicks a button, Loopyard punches a hole to the outside world for one workspace's service. Port bookkeeping is the plumbing that makes that safe and traceable; it isn't the feature. The design follows from that.

## Model

- **One global pool** of host ports (`port_range: 4000..9999` by default).
- **Workspaces request ports one at a time** via `PortRegistry.assign(workspace_id, service, container_port)`. The registry picks the lowest unused port in the pool, records the entry, returns it.
- **Sticky within a workspace lifecycle.** Same `{workspace_id, service, container_port}` → same host port across restarts. Released when the workspace is destroyed; no promise of stability across delete/re-add.
- **No reservations, no blocks, no contiguity guarantees.** In practice `compose up` serializes the assigns for one workspace and ports come out contiguous anyway. If they don't one day, nobody notices — the sidebar shows service name + dot color, not port spatial patterns.
- **Every port binds `127.0.0.1`.** Compose stays that way forever. Exposure (v2) is a separate TCP proxy in front of the loopback port, not a compose rewrite.

No project-level bookkeeping. No base port. No `block_size`. The pool is a flat integer range; the registry is one ETS table.

## Data

One ETS table owned by `StateKeeper`:

- `:port_registry_entries` — `{{workspace_id, service, container_port}, entry}`

```elixir
%{
  workspace_id: "dd73",
  service: "dev",
  container_port: 3000,
  host_port: 4012,
  exposed: false,       # v2 adds the toggle; v1 writes false, never reads it
  legacy: false,        # true = migrated from capture_port_map; see "Migration"
  allocated_at: ~U[...]
}
```

Persisted as JSON to `~/.loopyard/ports.json` via a new `Loopyard.PortStore`. Write-through on every `assign` / `release`.

```json
{
  "version": 1,
  "port_range": [4000, 9999],
  "entries": [
    {"workspace_id":"dd73","service":"dev","container_port":3000,"host_port":4012,"exposed":false,"legacy":false}
  ]
}
```

## API

`Loopyard.PortRegistry` — GenServer for writes to serialize the "lowest unused port" search; ETS for reads.

```elixir
@spec assign(workspace_id, service, container_port) :: {:ok, host_port} | {:error, :port_pool_exhausted}
@spec get(workspace_id, service, container_port) :: {:ok, entry} | :none
@spec list_for_workspace(workspace_id) :: [entry]
@spec release_workspace(workspace_id) :: :ok

# Migration only; delete one release window later.
@spec seed(workspace_id, service, container_port, host_port) :: :ok
```

That's the whole API. Four public functions plus one migration helper.

`assign/3` semantics:
1. Return existing entry if `{ws, svc, cport}` already present (sticky).
2. Scan the pool for the lowest integer in `port_range` not present in any entry's `host_port`. Insert + return.
3. If every port in range is taken, return `{:error, :port_pool_exhausted}` with an operator-actionable message. (At default config that's 6000 ports in use, which means something has gone very wrong.)

Under a GenServer for writes so two concurrent `assign` calls can't race and double-assign the same port. Reads (`get`, `list_for_workspace`) go straight to ETS.

## Compose integration

`Loopyard.Compose.process_agent_compose/3`:

- Drop the `:port_map` option.
- In `process_services`, for each service `svc` with a `ports:` entry:
  - Extract `container_port` (existing `extract_container_port/1`).
  - `{:ok, host_port} = PortRegistry.assign(workspace_id, svc_name, container_port)`.
  - Emit `"127.0.0.1:#{host_port}:#{container_port}"`.
- `validate_service_ports` unchanged — agents still can't pin host ports.
- `capture_port_map/1` kept for one release cycle for migration, then deleted.

## Lifecycle integration

- `Workspace.Destructor.destroy/1` calls `PortRegistry.release_workspace/1` after `compose_down`.
- `ProjectRegistry.remove_project/1`: the existing per-workspace `Destructor.destroy` loop covers it; no separate project-level release.
- Application supervisor boots `PortRegistry` before anything that calls `assign/3` — after `StateKeeper` (ETS tables) and `ProjectRegistry.restore/0` (so existing workspaces exist for the migration seed).

## URL tooling

- `Docker.Observer.services_for/1` merges `PortRegistry.list_for_workspace/1` (the mapping) with Observer's container state (`:running` etc.). Registry has entries even when containers are stopped, so the sidebar link survives `compose down`.
- `Tools.Container.AppUrl.find_host_port/2`: try `PortRegistry.get/3` first, fall back to Observer's container port scan.
- `FileUrl` is path-based, unaffected.

## Migration

On first boot after upgrade, `PortRegistry.restore/0`:

1. If `ports.json` exists → load, done.
2. Otherwise for each known workspace: `Compose.capture_port_map(ws_id)` → `%{service => %{container => host}}`. Insert each as `legacy: true`.
3. Save `ports.json` so the legacy path runs exactly once.

Legacy entries: if a legacy host port lives outside the configured `port_range` (unlikely but possible with a tight range config), the entry stays valid but the allocator's "lowest unused in range" scan skips it. Sticky for the life of the affected workspaces; no forced renumber.

## Config

`config/config.exs`:

```elixir
config :loopyard, Loopyard.PortRegistry,
  port_range: 4000..9999
```

Env overrides: `LOOPYARD_PORT_RANGE_MIN`, `LOOPYARD_PORT_RANGE_MAX`.

Document in `docs/CONFIG.md`.

## Security model update

`docs/SECURITY.md` § 4 "Network isolation" becomes:

> Each workspace gets its own default Compose network. Host port allocation is owned by `PortRegistry`: one global pool (default `4000..9999`); workspaces request ports one at a time; assignments are sticky for the life of the workspace. Agents can't pin host ports — `validate_service_ports` rejects anything with a host side. Every published port binds `127.0.0.1`. Cross-workspace reach via `<docker-host-ip>:<port>` is blocked by default. Exposure to the LAN / a tunnel is an explicit operator action (see v2) implemented as a TCP proxy in front of the loopback port, not a compose rewrite — so enabling exposure doesn't restart the container, and disabling it closes the public listener immediately.

Add to "When adding or changing code":
- *Ports: any new path that publishes a host port must call `PortRegistry.assign/3`. No `docker run -p` with a hardcoded host port. No compose `ports:` line with a host-side value.*

## Tests

New `test/loopyard/port_registry_test.exs`:
- `assign/3` returns existing entry on repeat (sticky)
- `assign/3` across different `{ws, svc, cport}` triples returns distinct host ports
- `assign/3` picks the lowest unused port in the range
- `release_workspace/1` deletes all entries for that workspace; subsequent `assign` reuses the freed ports
- Pool exhaustion returns `{:error, :port_pool_exhausted}`
- `seed/4` inserts a legacy entry that counts as in-use for future `assign` but doesn't double-count if called twice with the same key

New `test/loopyard/port_store_test.exs`:
- Round-trip load/save preserves `legacy: true` / `exposed: false` fields
- Missing file returns empty state
- Invalid JSON returns empty state + logs warning

Modify `test/loopyard/compose_test.exs`:
- `process_agent_compose/3` emits `127.0.0.1:<registry_port>:3000` using a test-seeded registry
- Repeat call yields the same host port (sticky via registry)
- Host port pin rejection still works (existing test)

New integration `test/loopyard/workspace_port_flow_test.exs`:
- Full path: compose with `ports: ["3000"]` → processed YAML has the registry-assigned port → `Destructor.destroy` releases the entry

## v1 scope

Everything in this document. Specifically:

- `PortRegistry` GenServer + `PortStore` JSON persistence
- `Compose.pin_port/2` replaced by a `PortRegistry.assign/3` call
- `Destructor.destroy/1` releases
- `Observer.services_for/1` and `AppUrl.find_host_port/2` prefer registry
- Migration path (seed from `capture_port_map/1` on first boot)
- Config + CONFIG.md + SECURITY.md wording update
- Tests listed above

v1 ships with `exposed: false` on every entry. The field is written so v2 has a slot to flip; it's never read in v1.

## v2 (next session) — the actual feature

Two halves, shipped together because one without the other is unsafe:

**Exposure mechanism (punch the hole):**
- `PortExposer` GenServer + `DynamicSupervisor`. Elixir `:gen_tcp` proxy listening on `0.0.0.0:<host_port>`, forwarding to `127.0.0.1:<host_port>`. No compose rewrite, no container restart.
- Sidebar padlock toggle next to the `:<port>` link. Closed = loopback-only; open = exposed. Operator-only (Phoenix UI user; agents cannot enable).
- Confirmation dialog before exposing ("Other devices on your network will be able to reach this dev server.")
- Same open/close/remove buttons available on the workspace sidebar row AND the service detail view, so the operator can act from wherever they spot the problem.
- EventLog entry on expose / revoke (auditable).
- `exposed: bool` on the registry entry is persisted in `ports.json`, restored on boot. If a restart finds entries with `exposed: true`, `PortExposer` re-opens the listener automatically.

**System → Ports page (see what's open):**
- New `/system/ports` route. Lists every entry in `PortRegistry` — one row per `{workspace, service, container_port}`.
- Columns:
  - **Port** — host port + padlock icon (open/closed).
  - **Service** — `dev`, `postgres`, `redis`, etc.
  - **Workspace** — name, links to the workspace view.
  - **Project** — name, links to the project page.
  - **Container** — container name + running/stopped dot, links to the container view.
  - **Activity** — bytes in/out since exposure opened, current connection count.
  - **Connected IPs** — list of remote peers currently connected to the proxy (captured from `:gen_tcp.peername/1` on accept). Only populated when `exposed: true`.
  - **Actions** — Open / Close / Remove buttons per row. "Remove" tears down the entry AND stops the underlying container (delegates to `Compose.compose ["stop", svc]` or similar).
- Activity counters live on the `PortExposer` GenServer. Each child process already sits in the TCP data path: accept → forward bytes in both directions → increment counters. Bump counters on every `gen_tcp.recv` / `gen_tcp.send` round trip. Readable via a GenServer call from the LiveView.
- Counters don't persist — they reset when the exposer restarts (BEAM restart, or toggle off/on). This is fine: activity is a "what's happening right now" view, not an audit log. Audit trail lives in EventLog.
- No real rate or throughput graphs in v2 — counters and current-connections are enough. If graphs become interesting, the counters are already the source; a `:telemetry` hook + LiveChart plug in later.

**Same buttons on the workspace sidebar:**
- The padlock row on each service already does open/close.
- Add a "Remove" button on the service detail view that combines `stop_service` (existing) with `PortRegistry.release_workspace_service/3` (new) so the port is returned to the pool. Also stops the container via existing compose handlers.
- Confirmation: "Remove dev port and stop the container? The workspace's compose file still declares it — next `docker_compose up` will re-allocate."

## v3 (not planned in detail) — tunnels + graphs

- `PortExposer` dispatches on `:exposure_kind` (`:lan`, `:tunnel_cloudflare`, `:tunnel_tailscale`, `:tunnel_wireguard`). Each backend is a module with `start_link/1`, `stop/1`, `public_url/1`.
- Agent-requested exposure via an MCP tool that pushes a pending request into EventLog for operator approval.
- Throughput / latency graphs on the `/system/ports` page via `:telemetry` + a small time-series ring buffer. Counters from v2 are already the source.
- Per-port rate limiting and connection caps on the exposer (defense against accidentally exposing a dev DB to a noisy scanner).

## Implementation order (v1, single session)

1. Add `:port_registry_entries` to `StateKeeper.@tables`.
2. `PortStore` — load/save JSON.
3. `PortRegistry` GenServer — tests first, implementation second.
4. Wire `PortRegistry.restore/0` into the application supervisor after `ProjectRegistry.restore/0`.
5. Rewrite `Compose.pin_port/2` call site in `process_services` to call the registry. Update compose tests.
6. Drop `:port_map` option from `process_agent_compose/3` and its callers.
7. Add seed path in `PortRegistry.restore/0` for migration from `capture_port_map/1`.
8. `Destructor.destroy/1` → `PortRegistry.release_workspace/1`.
9. `Observer.services_for/1` + `AppUrl.find_host_port/2` prefer registry.
10. `docs/SECURITY.md` + `docs/CONFIG.md` updates.
11. Full targeted subtree run; no regressions.
