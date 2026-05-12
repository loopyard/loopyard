---
name: debug-ui
description: Diagnose LiveView UI flashes, re-render loops, and state/view mismatches by introspecting the running app via mix loopyard.rpc. Use when the user reports anything that "flashes", "flickers", "keeps changing", "blinks", "keeps updating", or when an assign is suspected of being overwritten. RPC-based — no browser needed.
user_invocable: true
---

# Debug UI: LiveView flash & re-render diagnosis

Diagnose why the running app's UI is re-rendering unexpectedly. **Go to the running data first.** Don't grep the code, don't ask the user to click things, don't take screenshots. `mix loopyard.rpc` gives you the truth in under 5 seconds.

The three flavors of this bug:

- **Data flipping** — an assign toggles between two values (annotated ↔ raw, full ↔ partial). Most common.
- **Data stable, LiveView re-renders anyway** — same value being reassigned fires a render every time. Wasteful; sometimes causes flicker via transitions.
- **Data AND renders stable, but UI looks weird** — not this skill. That's a CSS/animation/layout question; use the `agent-browser` skill or devtools.

Each recipe below tells you which flavor you're looking at.

## Prerequisites

- Loopyard running on `localhost:4000` (`mix loopyard.server`)
- You're in the Loopyard repo root

Check liveness first:

```bash
mix loopyard.rpc 'Node.self()'
```

If that errors, the server is dead — tell the user to `mix loopyard.server` before proceeding.

## Recipe 1 — "Is the data actually changing?" (assign diff)

**When:** user reports "X keeps flashing." First question: is the assign actually flipping?

```bash
mix loopyard.rpc '
pid = Phoenix.LiveView.Debug.list_liveviews()
      |> Enum.find(&(&1.view == LoopyardWeb.WorkspaceLive))
      |> Map.get(:pid)

snaps = for _ <- 1..25 do
  Process.sleep(200)
  :sys.get_state(pid).socket.assigns
end

diffs =
  snaps
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.map(fn [a, b] ->
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.filter(fn k -> Map.get(a, k) != Map.get(b, k) end)
  end)

diffs
|> List.flatten()
|> Enum.frequencies()
|> IO.inspect(label: "Keys that changed (over 5s)")
'
```

Substitute the LiveView module name for whichever page the user is on. If the user gives you a URL, the module is in `lib/loopyard_web/router.ex`.

**Read the result:**

- `%{}` → no assigns changed. Go to Recipe 3 (render counter).
- `%{some_key: N}` → that assign changed N times. Go to Recipe 2.

## Recipe 2 — "What changed inside the assign?" (field-level diff)

**When:** Recipe 1 showed a key flipping. Find which field inside the value differs.

```bash
mix loopyard.rpc '
pid = Phoenix.LiveView.Debug.list_liveviews()
      |> Enum.find(&(&1.view == LoopyardWeb.WorkspaceLive))
      |> Map.get(:pid)

key = :service_statuses   # replace with the key from Recipe 1

for _ <- 1..60, reduce: nil do
  prev ->
    Process.sleep(100)
    cur = :sys.get_state(pid).socket.assigns[key]
    if prev && cur != prev do
      Enum.zip(List.wrap(prev), List.wrap(cur))
      |> Enum.each(fn {a, b} ->
        changed =
          Map.from_struct(a)
          |> Enum.reject(fn {k, v} -> Map.get(b, k) == v end)

        if changed != [] do
          name = Map.get(a, :name) || inspect(a)
          IO.puts("--- #{name} changed:")
          Enum.each(changed, fn {k, v} ->
            IO.puts("  #{k}: #{inspect(v)} -> #{inspect(Map.get(b, k))}")
          end)
        end
      end)
    end
    cur
end
:ok
'
```

**Read the result:**

- `field: real_value → nil` (or vice versa) → **un-annotated overwrite**. Some handler is writing a raw version over a path that had extras merged in. Go to Recipe 4 to find the writer.
- `field: value_a → value_b` (both real) → real state transition. Check whether the broadcast that triggered it *should* have fired, or whether an Observer-style cache is comparing on volatile fields (uptime strings, byte counts, timestamps).

## Recipe 3 — "Is the LiveView re-rendering without reason?" (render counter via telemetry)

**When:** Recipe 1 said no assigns changed, but the user still sees flash. Attach a telemetry handler to count renders + broadcast receives.

```bash
mix loopyard.rpc '
# One-shot telemetry attach: count render events on a specific LV pid for 5s.
pid = Phoenix.LiveView.Debug.list_liveviews()
      |> Enum.find(&(&1.view == LoopyardWeb.WorkspaceLive))
      |> Map.get(:pid)

parent = self()
id = {:debug_ui, System.unique_integer()}

:telemetry.attach_many(
  id,
  [
    [:phoenix, :live_view, :render, :stop],
    [:phoenix, :live_view, :handle_info, :stop],
    [:phoenix, :live_view, :handle_event, :stop]
  ],
  fn event, _measure, meta, _cfg ->
    if meta[:socket] && meta.socket.root_pid == pid do
      send(parent, {:evt, event, meta[:event] || meta[:message]})
    end
  end,
  nil
)

Process.sleep(5000)
:telemetry.detach(id)

# Drain mailbox
events =
  Stream.repeatedly(fn -> receive do msg -> msg after 0 -> nil end end)
  |> Stream.take_while(&(&1 != nil))
  |> Enum.to_list()

events
|> Enum.group_by(fn {:evt, ev, _} -> ev end)
|> Enum.each(fn {ev, list} -> IO.puts("#{inspect(ev)}: #{length(list)}") end)
'
```

**Read the result:**

- `render: 0` → LiveView is not re-rendering at all. Flash is pure client-side (CSS animation, JS hook). Hand off to `agent-browser` skill or devtools.
- `render: N, handle_info: M` with N ≈ M → every message causes a render. Probably fine if assigns are actually changing. If Recipe 1 said assigns DON'T change but renders are happening, something is calling `assign(socket, key, same_value)` — LiveView diffs to nothing but the render still fires. Grep for writers that don't compare before assigning.
- `render: N, handle_info: 0` → renders without triggering messages. Rare; could be a `push_event` loop or lifecycle hook. Inspect `socket.private` for active patches.

## Recipe 4 — "Who writes this assign?" (source audit)

**When:** Recipe 2 nailed the flipped field and you need to find the code path that strips it.

Grep for `assign(socket, :<key>` and `|> assign(:<key>` across `lib/loopyard_web/`. For each hit, trace the source of the value being assigned. Look for the odd one out — the handler that assigns a raw version when every other handler assigns the enriched version (the one that calls helpers like `annotate_exposure`, `load_sidebar_from_observer`).

Classic shape of this bug: a `handle_info(%Events.<Topic>.<Struct>{...}, socket)` clause that assigns raw payload fields directly, when another clause for a different event struct enriches the same assign first. `git log --oneline` for `"flash"` for a worked example. The event struct names live in `lib/loopyard/events/` — grep the struct name to find every producer and consumer.

## Anti-patterns to flag

Same bug class the sidebar-flash incident hit. Watch for these during any audit:

1. **Async task broadcasts raw cache data to a LiveView that expects enriched data.** Task should only ship what's *new* (logs, results), not re-ship cache contents. LiveView keeps its own fresh copy from other broadcasts.
2. **Observer-style broadcast compares on volatile fields.** Uptime strings, byte sizes, timestamps → snapshot always compares unequal → spams `state_changed`. Compare a reduced functional signature; put volatile data in a separate ETS slot.
3. **Broadcast carries a state payload the LiveView ignores.** LV re-reads from ETS anyway. Payload is wasted serialization AND a drift risk — future code might consume the payload and get a different view than the cache. Prefer notification-only broadcasts on notification-only event structs.

## `/system/events` — the tape

If the user reports a flash AND wants to see the broadcast timeline, skip the telemetry attach (Recipe 3) and go to `/system/events` directly. It's a live ring buffer of every broadcast on every topic (shipped with coordination hardening Move #7). You can also read it via RPC:

```bash
mix loopyard.rpc 'Loopyard.Events.Tap.recent("chat_agents", 30_000)'
```

Use this to correlate a reported flash with the exact broadcast sequence that caused it. All publishes go through `Loopyard.Events.*` publisher modules (never raw `Phoenix.PubSub.broadcast`); the event type is the struct name (`%Events.ChatAgent.StatusChanged{}`, `%Events.DockerObserver.Changed{}`, etc.). Grep that struct name to find every site that produces or consumes the event.

## Choosing between recipes

| User says | Start with |
|-----------|------------|
| "keeps flashing / flickering / blinking" | Recipe 1 |
| "X disappears and reappears" | Recipe 1 → 2 |
| "button keeps updating to the same thing" | Recipe 1 (expect `%{}`) → Recipe 3 |
| "the count is wrong / keeps resetting" | Recipe 1 → 2 |
| "it looks wrong but the data is fine" | Not this skill — CSS/layout; use `agent-browser` or ask user to open devtools |

Default: run Recipe 1 immediately. Don't ask the user to click, screenshot, or describe the UI further. The data either tells you what's flipping or tells you it's not a state problem.
