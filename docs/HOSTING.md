# Hosting Loopyard

Loopyard is meant to be a personal, always-on server: one Mac (or Linux box) runs it, and you reach it from a desktop and a phone. This doc covers running it as a service that survives terminals, crashes and reboots, giving the phone an address that doesn't change, and keeping the machine awake.

## Install the service

From a Loopyard checkout:

```bash
mix loopyard.service install --checkout ~/loopyard-server
```

That:

1. Clones this checkout into `~/loopyard-server` (a local clone, on `main` — `--branch` picks another), points its `origin` at this checkout's upstream, and runs `mix deps.get`, `npm ci --prefix assets` and `mix compile` there. An existing `--checkout` directory is used as it is.
2. Writes the launch script `${LOOPYARD_HOME}/service/run.sh` and the service definition — on macOS the LaunchAgent `~/Library/LaunchAgents/ai.loopyard.server.plist` (`RunAtLoad` + `KeepAlive`), on Linux the systemd user unit `~/.config/systemd/user/loopyard.service` (`Restart=always`).
3. Records what it installed in `${LOOPYARD_HOME}/service.json`, so `status`, `restart`, `update` and `logs` act on the installed checkout from any directory.
4. Loads the service, which starts `mix loopyard.server` from the checkout right away, and prints its status and addresses.

The service's environment is fixed at install time: a `PATH` holding the directories `mix`, `elixir`, `erl`, `git`, `docker`, `colima`, `mutagen`, `npm`, `node`, `tailscale` and `cloudflared` resolve to now (launchd and systemd start with a bare `PATH`), `HOME`, `LANG=en_US.UTF-8`, `LOOPYARD_HOME`, `PORT` (`--port`, default `$PORT` or 4000), `LOOPYARD_BIND` (`--bind`, default `$LOOPYARD_BIND` or loopback) and `MIX_ENV=dev`. `LOOPYARD_MCP_PORT`, `LOOPYARD_MCP_URL` and `SSH_PORT` are passed through when set. Anything else (`LOOPYARD_AUTH_PASSWORD`, …) goes in the checkout's `.env`, which `config/runtime.exs` reads at boot; the plist/unit is world-readable, so secrets never go in it. Upgraded Elixir, or moved a tool? Run `install` again — it replaces the definition in place.

**Install refuses while another server holds the port.** If `mix loopyard.server` is running in a terminal, stop it first. Loading the service next to it would not just fail to bind: every crash-looping boot runs the stale-harness reap for the Loopyard home both share, which would kill the terminal server's live agent harnesses every ten seconds.

`install` without `--checkout` runs the service from the current checkout. It works, and it says why you shouldn't:

### Why a dedicated checkout

The server runs in dev mode with the code reloader on: every request recompiles whatever changed in the checkout it runs from. An edit there that doesn't compile — yours, or an agent's halfway through a change — freezes every page of the server you rely on, phone included, until someone fixes it from a terminal. A dedicated checkout only moves when you say so, and `update` only moves it to code that compiles. Develop Loopyard in your usual checkout; let the service run from the other one. There is no release build: the service runs the same `mix loopyard.server` you would.

## Day to day

```bash
mix loopyard.service status     # state, pid, checkout revision, log paths, every address
mix loopyard.service update     # fast-forward the service checkout, compile, restart
mix loopyard.service restart    # restart in place (launchctl kickstart -k / systemctl restart)
mix loopyard.service logs       # last 100 lines of each log; --follow to tail, --lines N
mix loopyard.service uninstall  # stop, unload, remove the definition (logs are kept)
```

**`update`** refuses a checkout with uncommitted changes, then runs `git pull --ff-only`, `mix deps.get` (and `npm ci` when `assets/package-lock.json` moved) and `mix compile` in the service checkout, with `MIX_ENV=dev` and no inherited `MIX_BUILD_PATH`, so it builds the checkout's own `_build/dev`. Only when that compiles does it restart the service. When it doesn't, the checkout is put back on the old commit (`git reset --keep`) and the server is left running; the error shows the compiler's output. Nothing to pull means no restart.

Agents survive a restart: each one's conversation is resumed from Loopyard's own log (see CLAUDE.md → "Agent reliability invariants").

### Why it's down

1. `mix loopyard.service status` — is it `running`? A crash-looping service shows a changing pid and a `last exit` code. launchd restarts at most every 10 s (`ThrottleInterval`); systemd every 10 s, forever (`StartLimitIntervalSec=0`).
2. `mix loopyard.service logs` — two files under `${LOOPYARD_HOME}/logs/`:
   - `service.log` — the process's stdout/stderr: the start banner, compile errors, a crash before the logger is up. Moved to `service.log.1` when it passes 1 MB, at the next start.
   - `server.log` — the server's Logger output (OTP's rotating file handler: 5 files of 10 MB). With `LOOPYARD_LOG_FILE` set, `mix loopyard.server` logs here instead of to stdout.
   - `launchd.log` (macOS) catches anything launchd prints before the script redirects its output; normally empty.
3. A compile error in `service.log` means the checkout has code that doesn't build — that's what `update`'s rollback is for. Fix it, or `git -C <checkout> reset --keep <good sha>` and `restart`.

### After a reboot

On macOS a LaunchAgent starts when **you log in**, so for a hands-off reboot turn on automatic login (System Settings → Users & Groups; FileVault blocks it, in which case the service starts at your first login). On Linux a user unit starts with your first session unless you run `loginctl enable-linger $USER` once.

The server usually comes up before the container runtime. That's handled in the app, not in the service: `DockerDaemon` probes the daemon, starts Colima itself when it's down (`colima start`, no sudo), and on the down→up transition re-registers the projects whose volumes it couldn't see at boot, replays their agents, and starts every workspace that was in use (`Workspace.Autostart`). Don't also run Colima as a separate login item or brew service — the two would race at login.

## A stable address for the phone

A quick-tunnel URL changes on every restart; a bookmark needs a name that doesn't. Two ways, both of which work with the server bound to loopback (the default). `mix loopyard.service status` lists every address it can find.

The LiveView websocket accepts any hostname: dev's endpoint runs with `check_origin: false` (`config/dev.exs`). A proxy name never matches the endpoint's `url: [host:]`, and Phoenix's `check_origin: :conn` also compares scheme and port, which an HTTPS proxy in front of plain HTTP never satisfies — so tightening it would load the page on the phone and then never connect. `test/loopyard/hosting/addresses_test.exs` guards it.

### Tailscale (private, recommended)

Install Tailscale on the Mac and the phone and sign both into the same tailnet. Then, on the Mac:

```bash
tailscale serve --bg 4000
```

The app bundle's CLI works too: `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 4000`. This publishes `https://<machine>.<tailnet>.ts.net` to your tailnet only, with a real certificate (HTTPS is what lets the phone install the app and receive Web Push), proxied to `127.0.0.1:4000`. It persists across reboots. `status` shows it as `tailnet https://… (tailscale serve)`, or prints the command above when the name exists but nothing is published yet.

If you bind `LOOPYARD_BIND=0.0.0.0`, the tailnet IP (`http://100.x.y.z:4000`) works too — but that also exposes the server to the whole LAN; with `tailscale serve` you don't need it.

### A named Cloudflare tunnel (public hostname)

For a hostname on your own domain, use a **named** tunnel (not `cloudflared tunnel --url`, which is the throwaway kind):

```bash
cloudflared tunnel login
cloudflared tunnel create loopyard
cloudflared tunnel route dns loopyard loopyard.example.com
```

`~/.cloudflared/config.yml`:

```yaml
tunnel: loopyard
credentials-file: /Users/you/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: loopyard.example.com
    service: http://localhost:4000
  - service: http_status:404
```

Run it as its own service (`sudo cloudflared service install`, or `brew services start cloudflared`). `status` lists every `hostname:` whose `service:` points at the Loopyard port. A public hostname is reachable by anyone who finds it: put Cloudflare Access in front of it, or set `LOOPYARD_AUTH_PASSWORD` in the checkout's `.env`. Credential-push routes already demand a token over a tunnel (`LoopyardWeb.PushAuth`).

## Binding and remote shell

The server binds `127.0.0.1:4000` by default. Where it listens is a **boot flag**, not runtime state: `LOOPYARD_BIND=0.0.0.0` (passed with `install --bind 0.0.0.0`) exposes it to the LAN; a bad value falls back to loopback (`config/dev.exs`). There is deliberately no UI toggle: it was reachable over the very connection it controlled, so flipping it to "private" from a phone could sever your only link.

`mix loopyard.server` (what the service runs) starts EPMD and boots the BEAM as `loopyard@127.0.0.1` with the cookie at `~/.loopyard/cookie` (always `~/.loopyard`, never `$LOOPYARD_HOME`), which is what makes `mix loopyard.rpc "..."` work from any terminal on the machine — including against the service.

## macOS power management

By default, macOS sleeps the machine when displays turn off. That kills the server for every client until someone wakes the machine.

**Disable system sleep, keep display sleep:**

```bash
sudo pmset -a sleep 0
```

Displays still turn off, but the CPU and network stay up, so the server stays reachable over the LAN, the tailnet and tunnels. An idle Mac Studio (M1 Max) draws 6–10 W — roughly $1–2 a month.

Wake on LAN (System Settings → General → Sharing → "Wake for network access") wakes the Mac only on magic packets, not on ordinary HTTP requests; `sleep 0` is the reliable setting.

Check with `pmset -g`. You want `sleep 0`, any `displaysleep`, and `networkoversleep 1` as a backup.

## When the Docker disk fills up

Everything Loopyard runs lives on the Docker VM's disk (Colima's, by default
~100 GB). When it fills, `docker exec` fails with "no space left on device"
and every agent turn dies. Loopyard watches it:

- `/system` has a **Docker disk** row — degraded below 5 GB free, down below
  500 MB or once a write has failed (thresholds: `docs/CONFIG.md`).
- The Notifications inbox gets ONE item naming the cause and what to do; it
  settles on its own once space is back.
- An agent whose harness couldn't launch says the disk is full instead of
  retrying into it.

Loopyard frees what it safely can **by itself**: every hour, and at once when
the disk row turns degraded or down, it removes its own provably-unused
leftovers (dangling test-suite volumes, finished sign-in / copy containers,
superseded `loopyard-workspace-base` tags). A leftover goes only after an
earlier look, ten minutes before, already saw it. It also cleans up where
things are disposed: destroying a workspace removes its containers, volumes
and the images its dev cluster built.

The rest is yours to decide, and it is one tap from a phone. The inbox alert's
**Free up space** opens `/system/docker`, which lists, each with its warning:

- **Stopped containers** that are not Loopyard's. Their volumes are kept;
  removing them also releases the images only they were holding.
- **Unused images.** Pulled or rebuilt when next needed.
- **Empty leftovers this server doesn't recognise**: `loopyard-<id>…`
  containers, images and EMPTY volumes whose id is not registered here. Usually
  a deleted workspace or an old test run. If another Loopyard shares this
  Docker they may be ITS containers, which is why this is never automatic. A
  running container under the live prefix, and anything a running container
  mounts, is never offered.
- **Leftover code and data this server doesn't recognise**, one at a time: the
  same unregistered ids' volumes that have something in them. A code volume can
  be the only copy of uncommitted or unpushed work, so there is no "remove all"
  for these.
- **Other unattached volumes**, one at a time. This is other tools' data.

Nothing is forced (Docker refuses anything in use, and the page says what it
kept), and each click is re-checked against a fresh look at the daemon.

From a terminal, the automatic tier is also a command:

```bash
mix loopyard.gc            # dry run: what is provably Loopyard's own and unused, with sizes
mix loopyard.gc --apply    # remove it (never forced; Docker refuses anything in use)
```

If Colima itself is out of room, `colima stop && colima start --disk <GB>`
grows the VM disk (it cannot shrink).
