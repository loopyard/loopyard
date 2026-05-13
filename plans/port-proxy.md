# Port Proxy Architecture

Docker ports are internal. Loopyard ports are what users see. All traffic
flows through Loopyard's proxy, giving full observability (connections,
bytes, peer IPs) in both private and exposed modes.

## Data flow

```
User (localhost or LAN)
  │
  ▼
PortExposer (gen_tcp proxy)
  listen: 127.0.0.1:4008 (private) OR 0.0.0.0:4008 (exposed)
  │
  ▼
Docker container
  listen: 127.0.0.1:<ephemeral>:3000 (internal, never shown to users)
```

## Port lifecycle

1. **Compose processing** (`Compose.process_agent_compose/3`):
   - Agent writes `ports: ["3000"]` in docker-compose.yml
   - `emit_port/3` calls `PortRegistry.assign(ws, svc, 3000)` → gets `4008`
   - Emits `"127.0.0.1::3000"` — Docker picks ephemeral, NOT the registry port
   - The registry port (4008) is for the proxy, not Docker

2. **After compose up** (`ServiceManager.do_start` or Observer):
   - Docker binds `127.0.0.1:<ephemeral>:3000`
   - Observer detects the ephemeral port from container inspection
   - `PortRegistry.set_docker_port(ws, svc, 3000, ephemeral)` stores it
   - PortExposer starts: `127.0.0.1:4008 → 127.0.0.1:<ephemeral>`

3. **Toggle exposure** (`PortRegistry.set_exposure/4`):
   - Stop proxy, restart with `0.0.0.0:4008` (or back to `127.0.0.1:4008`)
   - Same user-facing port number. No container restart.

4. **Container restart** (ephemeral port changes):
   - Observer detects new port mapping
   - `PortRegistry.set_docker_port` updates
   - Proxy reconnects to new upstream

## Registry entry shape

```elixir
%{
  workspace_id: "a866",
  service: "dev",
  container_port: 3000,
  host_port: 4008,          # user-facing, stable across restarts
  docker_port: 32782,       # ephemeral, changes on container restart
  exposed: false,            # 127.0.0.1 vs 0.0.0.0
  legacy: false,
  allocated_at: ~U[...]
}
```

## Key invariants

- `host_port` NEVER changes for a given {ws, svc, cport} triple (sticky)
- `docker_port` changes on every container restart (ephemeral)
- Proxy ALWAYS runs when docker_port is known (not just when exposed)
- Exposure = bind address toggle, nothing else
- User sees `host_port` everywhere (sidebar, URLs, QR codes)
- `docker_port` is internal plumbing, never shown in UI

## What to test

1. Compose emits `127.0.0.1::<cport>` (not pinned host port)
2. After compose up, docker_port is discovered and stored
3. Proxy starts on host_port, forwards to docker_port
4. Data flows both directions through proxy (echo test)
5. set_exposure(true) → proxy rebinds to 0.0.0.0, LAN reachable
6. set_exposure(false) → proxy rebinds to 127.0.0.1, LAN blocked
7. Container restart → new docker_port → proxy updates upstream
8. Multiple sequential connections work (accept loop reliable)
9. Proxy crash → transient restart → reconnects
10. host_port stays stable across server restarts (persisted)

## Files to change

- `lib/loopyard/port_registry.ex` — add `set_docker_port/4`, proxy lifecycle
- `lib/loopyard/port_exposer.ex` — always-on proxy, bind toggle, trap_exit
- `lib/loopyard/compose.ex` — `emit_port` emits ephemeral instead of pinned
- `lib/loopyard/workspace/service_manager.ex` — discover docker_port after up
- `lib/loopyard/application.ex` — supervisor children
- `test/loopyard/port_exposer_test.exs` — comprehensive proxy tests
- `test/loopyard/port_registry_test.exs` — docker_port lifecycle tests
