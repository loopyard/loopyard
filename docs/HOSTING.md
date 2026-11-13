# Hosting Loopyard

Loopyard is designed to run on a local Mac as an always-on dev server. This doc covers keeping it reachable.

## macOS power management

By default, macOS sleeps the machine when displays turn off. This kills the server — incoming connections time out until you physically wake the machine.

**Fix: disable system sleep, keep display sleep.**

```bash
sudo pmset -a sleep 0
```

Displays still turn off (saving the panel), but the CPU and network stay up. The server stays reachable over LAN and tunnels.

**Power cost:** An idle Mac Studio (M1 Max) draws 6-10 watts — less than a phone charger. Roughly $1-2/month on electricity. Not worth worrying about.

### Wake on LAN

Wake on LAN lets you send a magic packet to wake a sleeping Mac. Enable it in System Settings → General → Sharing → "Wake for network access." However, this only wakes from sleep on magic packets — regular HTTP requests won't wake the machine. The `sleep 0` setting above is more reliable.

### Verify settings

```bash
pmset -g
```

You want:
- `sleep 0` — system never sleeps
- `displaysleep 10` — displays off after 10 min (fine)
- `networkoversleep 1` — wake on LAN enabled (backup)

## Starting the server

```bash
mix loopyard.server
```

The server binds to `127.0.0.1:4000` by default (local only). Where it listens is a **boot flag**, not runtime state — set `LOOPYARD_BIND=0.0.0.0` in the environment before starting to expose it for LAN/tunnel access (`config/dev.exs`; a bad value falls back to loopback). There is deliberately no UI toggle: the old one was reachable over the very connection it controlled, so flipping it to "private" from a phone could sever your only link with no way back short of physical access.

`mix loopyard.server` also starts EPMD and boots the BEAM as a distributed node named `loopyard@127.0.0.1` (a loopback longname — hostname-derived names broke whenever macOS flipped the hostname), with the cookie read-or-created at `~/.loopyard/cookie` (always `~/.loopyard`, never `$LOOPYARD_HOME`). That is what makes `mix loopyard.rpc "..."` work from any terminal on the machine.

## Keeping it running

For a persistent server that survives terminal closure:

```bash
nohup mix loopyard.server > /tmp/loopyard.log 2>&1 &
```

Or use `tmux`/`screen` to keep the session alive.

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

To free space:

```bash
mix loopyard.gc            # dry run: what is provably Loopyard's own and unused, with sizes
mix loopyard.gc --apply    # remove it (never forced; Docker refuses anything in use)
```

`gc` only ever takes dangling test-suite volumes (`loopyard-test-*-code` and
friends), stopped sign-in / copy throwaway containers, and superseded
`loopyard-workspace-base` tags. It never touches a workspace's code volume, a
workstation home, a compose project's volumes, or anything not named by
Loopyard. Its output ends with the largest OTHER volumes and images — usually
the real culprits (a compose project's `dind-data`, an old dev image, another
tool's cache). Those are yours to decide about: `docker system df -v` shows
them all, and `docker volume rm` / `docker image rm` removes what you choose.
If Colima itself is out of room, `colima stop && colima start --disk <GB>`
grows the VM disk (it cannot shrink).
