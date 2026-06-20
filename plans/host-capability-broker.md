# Host capability broker

How a workspace cluster reaches a host/external capability (the host Docker
daemon, a headless browser, a host DB, an LLM endpoint, …) **without** punching
a hole in the sandbox. Decided in a design session (2026-06-19).

> **One broker, many adapters. The sandbox stays sealed by default; a capability
> is a control-plane-granted, scoped, audited *seam* — never a compose directive
> the agent writes.**

This generalizes the pattern Loopyard already uses for ports (`PortExposer`) and
credentials (normalized to `$HOME` files): **the agent can *request* a
capability; only the control plane *opens* it, scoped.** Docker is just the first
adapter.

## Prior art: this is the *live-service* cousin of credential ingress

We already do "expose an external resource into the sandbox, scoped, control-plane
-mediated" — that's exactly what credential ingress is. The broker is the same
idea for *live* resources instead of *static* ones:

| | Credential ingress (today) | Capability broker (this plan) |
|---|---|---|
| Resource | static secrets (Claude OAuth, GH token) | live services (Docker daemon, browser, host DB) |
| Form in sandbox | **files** in the `$HOME` volume | a **network endpoint** (`DOCKER_HOST`, CDP ws) |
| Scope unit | per-seat / per-home volume | per-cluster broker instance |
| Host-side intake | normalize keychain/env/OAuth → files | front the socket/service → allowlisted proxy |
| Boundary | secret never leaves `$HOME`; env via `.profile`, never `-e SECRET` | app never sees the raw socket/host; only the broker endpoint |

Same razor in both: **the sandbox never touches the raw external thing; the
control plane normalizes it into a narrow, sandbox-shaped surface** (a file, or a
proxied port). Worth keeping the two consistent — e.g. a capability that needs a
credential (a host DB password, a browser auth) composes the two: broker fronts
the live endpoint, `$HOME` holds the secret it authenticates with.

## Non-negotiables (don't regress these)

1. **Default-sealed stays default-sealed.** `Compose.process_agent_compose/3`
   keeps rejecting host bind mounts, `privileged`, host net/namespaces,
   `devices:`, external networks, host port pins. A broker capability is *not* an
   exception carved into compose processing — it's a separate, control-plane-only
   injection.
2. **Agent requests, control plane grants.** The agent never writes the raw
   resource (no `/var/run/docker.sock` in its compose). It declares a capability
   *need*; the control plane decides, scopes, and wires the broker endpoint in.
3. **The broker is the only thing that talks to the host resource.** Workspace
   containers reach the *broker* (on the cluster network), never the raw host
   socket/service. The broker is where policy + audit live.
4. **Every grant is audited.** Through `EventLog` + the system surfaces, like
   every other control-plane action.

## Shape

The broker is a **control-plane-managed sidecar** injected into a workspace's
compose network the same way the code volume and identity home are injected
(`Compose.inject_*`) — the agent can't see or remove it. It exposes each granted
capability at a **stable in-cluster name** the app can point at:

```
workspace cluster (Loopyard-owned bridge network)
  ├─ workspace container (agent)   ─┐
  ├─ app services (postgres, …)     ├─→  loopyard-broker  ──(policy)──→  host/ext resource
  └─ …                             ─┘     e.g. DOCKER_HOST=tcp://loopyard-broker:2375
                                          e.g. CDP at ws://loopyard-broker:9222
```

Each capability is a **pluggable adapter** behind one broker process (or a small
set of sidecars — TBD, see open questions). An adapter owns: the upstream it
fronts, the allowlist, the name/label scoping, and the audit hook.

| Adapter | Fronts | Exposed as | Policy |
|---|---|---|---|
| **docker** | host Colima daemon (siblings) | `DOCKER_HOST=tcp://loopyard-broker:2375` | allowlist API verbs; label-scope; name-prefix (below) |
| **browser** | headless Chrome (broker-run, or a host CDP) | `ws://loopyard-broker:9222` (CDP) | one target/context per workspace; no host-fs; URL/nav policy TBD |
| **host-service** | a specific host TCP/HTTP service | `loopyard-broker:<port>` | exact host\:port allowlist; no wildcard host net |

The generic value: anything we'd otherwise be tempted to expose via
`network_mode: host` or a raw socket becomes "add an adapter + an allowlist."

## North star: each app gets its OWN cluster (isolation is the goal)

Two layers, don't conflate them:

1. **Declared stack — already isolated.** Each *workspace* is its own compose
   project on its own Docker-firewalled bridge network. An app whose stack lives
   in `.loopyard/workspace/docker-compose.yml` already *is* its own cluster. Not
   at risk.
2. **The agent's *ad-hoc* docker** — the app running `docker compose up` itself,
   testcontainers, `docker build`. THIS is where the dread is real: on a shared
   daemon those are loose siblings, not their own cluster, sharing the image
   namespace (the leak).

**Decision: each app's ad-hoc docker should also be its own isolated daemon =
its own cluster.** Speed is the constraint to engineer around, NOT a reason to
drop isolation. So the model is **sealed per-workspace daemon first**, and the
work is making sealed *fast*:

- **Sysbox runtime** (`runtime: sysbox-runc`) — a real inner dockerd per
  workspace, **no `--privileged`**, near-native via idmapped mounts. Each
  workspace's docker is fully its own (own image store, own everything) — no
  tag collisions, no cross-app leak. This is the target.
- **Kill the cold-start tax with a shared, read-only image cache.** The reason
  sealed feels slow is re-pulling `postgres:16` per workspace. Mount a shared
  **read-only** layer store / run a workspace-local **pull-through registry
  mirror** in front of Colima's cache, so first `up` is a cache hit without the
  daemons sharing writable state. Isolation (own daemon) + speed (shared RO
  cache) — the "have your cake."
- **Rootless DinD** as the portable fallback if Sysbox won't install into
  Colima's VM.

The earlier "siblings via proxy" is demoted to a **fallback** for when sealed
truly can't be made fast enough — fast, but it's the leaky one, so it's not the
default we're aiming for.

## The Docker adapter (proxy still matters — for the fallback + policy seam)

Even with a sealed daemon, the broker proxy is the seam that grants/scopes/audits
the capability (and is the whole mechanism in the sibling fallback). Fronted by a
filtered proxy (`docker-socket-proxy`-style), **never** a raw socket.

The proxy:
- **Allows** build / run / compose / logs / exec on the shared Colima daemon →
  full speed, full cache reuse.
- **Denies** the escapes that matter on each create/run: host bind mounts,
  `--privileged`, `--network host`, `--device`, and **any op targeting a
  resource not carrying this workspace's label**.
- **Stamps + scopes**: every container/network/volume the workspace creates gets
  `loopyard.workspace=<id>` and is **name-prefixed** `lyw-<id>-…`, and list/inspect/
  rm/kill are filtered to that label — so workspace A literally cannot see or
  touch workspace B's (or Loopyard's own, or `gbrain`/`openclaw`) containers.

### The honest leakage (a shared daemon = one flat namespace)

Access is strongly isolated by the label allowlist. **Names are only partly
isolated**, and this is the price of "fast":

| Namespace | Isolation | How |
|---|---|---|
| container access (see/rm/kill/exec) | **strong** | label allowlist on every op |
| container / network / volume **names** | **strong** | proxy prefixes `lyw-<id>-` transparently |
| **image tags** | **weak — residual leak** | the app's own compose/code says `myapp:latest`; rewriting that tag consistently across build+pull+run+code is brittle, so two workspaces building `myapp:latest` can stomp each other in the shared store |

**Accepted for a single-operator setup** (you control your own workspaces; you
won't often clobber yourself). For workspaces that genuinely need full name
isolation, the escape hatch is the **sealed-daemon opt-in** below — same broker
endpoint, different backing.

### Sealed-and-fast opt-in (later)

A per-workspace `docker` capability backed by its **own** daemon — fully isolated
image store (no tag collisions), at the cost of cache reuse. Options, fastest-path
first:
- **Sysbox runtime** (`runtime: sysbox-runc`) — real inner dockerd, **no
  `--privileged`**, near-native via idmapped mounts. Best if it installs into
  Colima's VM (unknown — spike it).
- Rootless DinD as the fallback (works, slower cold starts).

The point: the broker endpoint (`DOCKER_HOST=…broker…`) is **stable**; "shared
& fast" vs "sealed & slower" is a control-plane policy choice behind it, not an
app-visible change.

## How the agent opts in

The agent declares a capability *need* — NOT a raw resource. Candidate
mechanisms (pick in build):
- an MCP tool (`request_capability docker` / `browser`), mirroring `propose_*`
  human-gate cards, **or**
- a sanctioned compose annotation (`x-loopyard-capabilities: [docker]`) that
  `Compose.process_agent_compose/3` resolves into the broker injection — and
  which is the *only* compose key that can reach a host resource, still going
  through control-plane policy.

Either way: the agent's compose never contains the socket/host net; the control
plane injects the broker service + the `DOCKER_HOST`/CDP env + the scoped network.

## Security: the five reasons still hold

The current "five independent reasons agent A can't reach agent B" must survive:
the broker does **not** join clusters together (each workspace gets its own
broker instance / its own scoped view), the proxy's label allowlist is the new
structural reason a workspace can't touch another's siblings, and compose
processing is unchanged for everything else. New trust introduced = the broker's
allowlist correctness → so the allowlist is **deny-by-default**, unit-tested
against the escape verbs, and every grant is `EventLog`-audited.

## Build order

0. **Spike: can sealed be fast?** (Answer this BEFORE committing to a default.)
   Get Sysbox installed in Colima's VM (or prove rootless DinD); stand up one
   workspace with its own inner dockerd; measure cold `docker compose up` of a
   real stack (postgres+redis+app) — first with no cache, then with a shared
   read-only layer store / pull-through mirror. **Gate:** if warmed sealed start
   is within ~2× of sibling, sealed is the default and we never ship the leak.
   If it's hopelessly slow, fall back to sibling-via-proxy with eyes open.
1. **Docker adapter for the chosen backing, one workspace, behind the proxy.**
   Deny-by-default allowlist; tests for the deny verbs (bind mount, privileged,
   host net, cross-label rm). Prove a real app runs at acceptable speed in its
   OWN cluster.
2. **Generalize to the broker + adapter interface.** Extract the adapter
   behaviour; add the capability request path (MCP tool or compose annotation);
   `EventLog` audit; `/system` surface for live grants.
3. **Browser adapter.** Broker-run headless Chrome, one context/workspace, CDP at
   a stable name; nav/URL policy.

## Open questions

- One broker process with adapters vs one sidecar per capability? (blast radius
  vs container count.)
- Where does broker state/policy live — per-workspace config in `.loopyard/`?
- Browser: broker-run Chrome (sealed, simple) vs fronting a host CDP (the "call
  something on the host" idea — only if a host browser is genuinely wanted).
- Does the Docker adapter need compose *translation* too (the app's
  `docker-compose.yml` host-pins/bind-mounts that the proxy would reject at run
  time), or do we let those fail loudly with the existing actionable errors?
