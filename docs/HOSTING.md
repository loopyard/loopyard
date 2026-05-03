# Hosting BoomLooper

BoomLooper is designed to run on a local Mac as an always-on dev server. This doc covers keeping it reachable.

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
mix boom.server
```

The server binds to `127.0.0.1:4000` by default (local only). Use the Remote page (`/remote`) to expose on `0.0.0.0` for LAN/tunnel access.

## Keeping it running

For a persistent server that survives terminal closure:

```bash
nohup mix boom.server > /tmp/boomlooper.log 2>&1 &
```

Or use `tmux`/`screen` to keep the session alive.
