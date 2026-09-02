# SSH as an integration — key-auth via curl enrollment

**Status:** planned (2026-08-18, with Brad). The first *access* integration:
every integration so far provisions the box's identity toward a service
(GitHub token, Fly token). SSH is the first about a *person* getting in.

## The problem it fixes

`Loopyard.SSHServer` today: `no_auth_needed: true`, and `:ssh.daemon` is
started with **no `ip:` option → it binds all interfaces**. Locally fine (local
trust). On a LAN — and fatally on a WAN/hosted box — it's an unauthenticated
shell into the shared terminal (and thus the workstation's `env.json`, which
holds the GitHub + Claude tokens in plaintext). This is the SSH door from the
hosted-relay auth long pole (`plans/hosted-relay.md`).

## Design calls (made, not open questions)

**1. Two daemons, split by trust — not one clever peer-aware one.**
- **Local daemon**: bind `127.0.0.1` only, keep `no_auth_needed: true`. This is
  the *current* UX and it preserves the integration invariant "*works with
  NOTHING set up*." Binding it to loopback (instead of all interfaces) is a
  latent-bug fix worth shipping on its own, before anything hosted.
- **Network daemon**: bind `0.0.0.0`, **public-key auth required**
  (`no_auth_needed: false`, `user_dir` = the enrolled `authorized_keys`).
  Started only when the box is network-exposed (a boot flag, alongside
  `Loopyard.Bind` — reachability is a boot decision, never a runtime toggle).

This mirrors `PushAuth` (local = no token, remote = credential required) instead
of inventing a parallel model.

**2. Enrollment = curl your pubkey up the ingress we already have.**
The `PUT /workstations/:id/file/*path` ingress is PushToken-gated for remote
requests (`plans/archive/integrations.md`). Enroll with:

```bash
cat ~/.ssh/id_ed25519.pub | curl -T - \
  "https://<box>/workstations/:id/file/.ssh/authorized_keys?token=…"
```

Append semantics (multi-key — see multiplayer). **TOFU bootstrap:** the first
key needs the install PushToken (printed at setup / minted by the authed UI's
"Add SSH key"); after that the key is your auth. The upload MUST stay
token-gated — an open enroll endpoint just relocates the open door.

**3. `authorized_keys` lives host-side, under `LOOPYARD_HOME`.**
NOT the container `$HOME` where a normal `:file` integration writes — the SSH
daemon runs on the host and reads its `user_dir` there
(e.g. `<LOOPYARD_HOME>/ssh/authorized_keys`). Persists across restarts; never in
a code volume. This is the one bit of the integration that isn't pure data: the
`:file` push targets a host path, and the daemon flips to key auth.

## The integration entry (data)

```elixir
%{
  id: "ssh", label: "SSH",
  method: :file,
  file: ".ssh/authorized_keys",       # appended, host-side user_dir
  mac: "cat ~/.ssh/id_ed25519.pub",   # the Mac command that prints your pubkey
  connected_check: &keys_enrolled?/1,
  doc: "ssh"                          # priv/integrations/ssh.md
}
```

Plus `priv/integrations/ssh.md` (human- and agent-readable, per the framework).

## Multiplayer

Ships as **shared + anonymous**, exactly how multiplayer works today: the
terminal is a *shared session* (`terminal.ex`: "all viewers see the same
terminal"; the SSH channel is "raw byte I/O to a shared Terminal session").
There is no per-person identity model yet, and SSH does not need one to ship:

- `authorized_keys` is a **set** — every teammate curls their own key, all get
  in. "Multiplayer SSH" falls out for free.
- The key is a **gate** ("allowed in"), not yet an **identity** ("who you are").
  That matches the shared terminal, where nobody is attributed anyway.

**Per-person identity is the additive follow-on, explicitly out of scope for
v1.** When we want "Alice (ssh) is typing," that's `key → person` metadata on
top of the same `authorized_keys`, and the browser terminal grows the same
identity at the same time (same gap, same fix). SSH is the *forcing function*
for that model — it's the first place the box has to care who's at the keyboard
— but it is not blocked on it.

## Invariants

- **Never required.** Local daemon stays no-auth; empty enrollment → SSH still
  works locally, agents still boot. (`plans/archive/integrations.md` rule #1.)
- **Remote is always key-gated.** Network daemon never runs with `no_auth_needed`.
- **Enrollment is always PushToken-gated for remote.** TOFU on the install token.
- Host identity keys (`ensure_host_keys`) unchanged — those are the server's
  identity, separate from client `authorized_keys`.

## Build order

1. **Loopback-bind the current daemon** (`ip: {127,0,0,1}`). Standalone
   security fix, good with or without hosting. Small → main.
2. **SSH integration entry + `priv/integrations/ssh.md`** — the `:file` flow,
   host-side `authorized_keys` target, `connected_check`.
3. **Network key-auth daemon** — boot-flagged, `user_dir` = enrolled keys.
4. (later) per-person identity; SSH-over-relay; a revoke/list-keys UI.

## Out of scope

Per-person identity (its own follow-on, shared with the browser terminal);
relay transport for SSH (the relay forwards TCP; key auth on the daemon is the
robust layer regardless); key revocation UI.
