# Epic: the hosted relay — `*.loopyard.ai` in front of self-managed servers

**Status:** future. Nothing here is built. The one prerequisite (agents never
construct the outside address) shipped in `6fbac1ee`.

## The pitch

> "Install Loopyard on a server you run. We take care of the subdomain."

They manage the box — their Docker, their code, their compute, their upgrades.
We interface it to the outside world. No CF token, no ngrok, no port forwarding,
no DNS, no TLS. The thing people currently get stuck on stops existing.

## Why we host the edge instead of scripting Cloudflare

Wiring a tunnel is the worst kind of setup task: it fails in ways that look like
Loopyard is broken, and every provider fails differently.

* **Cloudflare quick tunnels** (`cloudflared tunnel --url`) — zero config, but a
  random `*.trycloudflare.com` every start, no way to reclaim a URL, explicitly
  not guaranteed. A URL that rotates on restart hands users dead links.
* **Cloudflare named tunnels** — stable, but need an account, an API token, a
  zone, and DNS records. That's a config surface we'd be supporting forever, in
  someone else's product, for every customer.
* **ngrok / others** — same shape, different flags.

We already run an Elixir server on `loopyard.ai`. An Elixir relay is a better
fit than orchestrating someone else's daemon: we own the protocol, the failure
modes, the reconnect semantics, and the observability — and it's the same
BEAM/Phoenix stack the team already reasons about.

## Shape

```
browser → https://<sub>.loopyard.ai → relay (Fly, Elixir) ─┐
                                                            │ persistent outbound
                                       Loopyard on THEIR box ┘  (they dial us)
```

The customer's server dials **out** to the relay and holds the connection; the
relay forwards requests back down it. Outbound-only means no inbound firewall
rule, no port forwarding, no public IP — the same property that makes tunnels
attractive, without the customer touching a tunnel.

**Note the direction:** this is the mirror of the existing
`curl -T … /workstations/:id/file/*path` ingress, where a remote machine pushes
INTO Loopyard. Same instinct ("run a script anywhere, no Docker required"),
opposite arrow. Worth keeping the two mental models distinct when documenting.

## Open questions (decide before building)

1. **Subdomain identity.** Per-server, per-workspace, or per-exposed-port? A
   workspace's dev server and its postgres are different things to expose.
   `<workspace>.<team>.loopyard.ai` reads well but bakes a hierarchy in early.
2. **Auth at the edge.** Who can open the URL? Options: unlisted-but-public
   (guessable = leaked), team SSO, or a signed link. Ties into
   `docs/SECURITY.md` — today Loopyard has no app auth by design (local-only
   assumption), and a public URL **breaks that assumption**. This is the item
   most likely to change other parts of the system; treat it as the long pole.
3. **Billing metric.** Bandwidth is the honest cost driver and the natural
   per-team unit, but it's hard for a customer to predict. Alternatives:
   per-seat, per-active-subdomain, or a bandwidth allowance with overage.
4. **Failure semantics.** Relay down, or customer box asleep (see
   `docs/HOSTING.md` — macOS power management) — the visitor should get a
   Loopyard-branded "this workspace is offline" page, not a raw 502.
5. **Upgrades.** "We upgrade it" was part of the pitch. Does the relay carry a
   version signal / self-update channel back to the customer's box? That's a
   second product surface hiding inside this one — scope it deliberately.

## What's already true (don't rebuild it)

* **`app_url` is the single source of the outside address** (`6fbac1ee`). When
  the answer becomes a `*.loopyard.ai` subdomain it changes in that one tool —
  no agent prompt edits, because agents are now forbidden from deriving URLs.
* **`PortRegistry` / `PortExposer`** already own per-service exposure and the
  loopback↔network toggle. The relay is a third exposure mode alongside
  local-only and LAN, not a parallel system.
* **`PushAuth`** already distinguishes local vs remote (tunnelled) requests and
  requires a `PushToken` for the latter — the auth seam for "this came from
  outside" exists.
* **`Loopyard.Bind`** already treats reachability as a boot flag, deliberately
  not a runtime toggle (a UI switch could strand you over the very connection it
  controls). The relay must not reintroduce that footgun.

## Sequencing

Prereq (done) → decide **auth at the edge** → relay MVP for one server, one
subdomain, no billing → multi-tenant + subdomain lifecycle → billing → the
"we upgrade it" story.

Auth is first because it can invalidate the rest of the design.
