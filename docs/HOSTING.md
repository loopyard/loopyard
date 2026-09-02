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
