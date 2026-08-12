---
name: removing-code
description: Rules for deleting code, or for "wiring up" something that looks orphaned. Load BEFORE removing a component/function/handler/CSS class, and before rendering anything that is defined but unreferenced. Covers the history check that distinguishes deliberately-removed from accidentally-dead, and the false-positive traps in this repo (aliases, packages/, macros, showcase scenes).
user_invocable: true
---

# Removing code (and the trap of "fixing" it)

Two failures, opposite directions, same root cause — treating the current state
of the tree as the whole story:

* **Deleting something that's alive.** A grep said zero references; the grep was
  wrong. (See "False positives" — every one of these fired in a real sweep.)
* **Re-adding something that was deliberately removed.** Code sat defined but
  unrendered. That read as an oversight, so it got wired up. It wasn't an
  oversight — it had been deleted on purpose, and putting it back was a
  regression the user had to catch twice.

The second is the more embarrassing one and the cheaper to prevent.

## Rule 1 — history before hands. Non-negotiable.

Before deleting a symbol, and **before rendering/calling anything that is
currently unreferenced**:

```bash
git log --oneline -S"<symbol>" -- <paths>   # every commit that added/removed it
git log -1 --format=%B <sha>                # WHY, in the author's words
```

Read the message. Then:

| History shows | Meaning | Do |
|---|---|---|
| Added, then its call sites removed | **Deliberate.** Someone decided this shouldn't be here. | Leave it. If it's dead weight, delete the definition too — never re-wire it. |
| Added, never referenced in any commit | Born dead. | Safe to delete. |
| Still referenced somewhere | Your grep missed it. | Go find it (see below). |

**A component defined but never rendered is a decision until history says
otherwise.** Real example: `detail_level_control` (the All\|Actions\|Chat
toggle). Unrendered → assumed orphaned → re-rendered → user: *"You put this
here a long time ago, it never made sense, I had you rip it out, and here it is
again."* One `git log -S` would have surfaced `ab605d9f`, which removed it and
explained why in the message.

**When you do delete, delete the tripwire too.** Leaving a component behind
after removing its render site is what invites the next resurrection. Take the
definition, its JS hook, its handler, its delegate, and the doc references —
and leave a short note at the deletion site saying it was removed and why.

## Rule 2 — a zero-hit grep is a hypothesis, not a finding

Search `lib/ packages/ test/ assets/ priv/ config/`. Then check these traps,
**all of which produced false positives in this repo**:

* **Aliases.** `alias Loopyard.Operator.Jobs` then `Jobs.delta(...)`. Grepping
  the full module name finds nothing. Search the last segment too.
* **`packages/`** is a second source root. `Hooks.Aural` looked dead because the
  grep only covered `lib/` — it's used by `packages/aural`.
* **Macro-generated.** `use Loopyard.Tool` emits functions that exist at no
  call site (`__reply__`, `__unwrap_frame__`).
* **Behaviour callbacks.** `@impl`, GenServer/Supervisor callbacks, `:logger`
  handler callbacks, Mix task `run/1`, `ssh_server_channel` callbacks.
* **Showcase scenes** mount components via capture (`&Mod.fun/1`), which a
  `<.fun` search misses. Scenes count as real usage.
* **LiveView-injected CSS.** `.phx-click-loading` / `.phx-submit-loading` are
  added at runtime and appear in no template.
* **Router shorthand.** `live "/review", ReviewLive` names the module without
  its namespace.
* **Event handlers** are reached by string, not symbol: check `phx-click=`,
  `phx-submit=`, `phx-change=`, `phx-blur=`, `phx-keyup=`, dynamic bindings
  (`phx-click={@row_click}`), and `pushEvent(` in `assets/js/`.

Test-only usage is its own category: report it, don't silently delete the test.

## Rule 3 — cut by structure, never by regex

Bulk edits across many files are where a "cleanup" turns into an outage. A
regex/line-range cut that walked backward over a `@doc` block left an
unterminated heredoc in `common.ex` and broke compilation **in the live
checkout while the user was working in it**. A second one left an orphaned
`@doc` that silently attached itself to the *next* function — that one
compiled, so it would have shipped wrong docs unnoticed.

* Read the actual boundaries first (`def` line → its matching `end`), including
  any preceding `@doc` / `attr` / `slot` / comment block. Assert on what you
  matched before deleting.
* Delete one symbol at a time and compile between.
* Never run a bulk removal script against a checkout a server is running from —
  see the `guard-live-build` hook.

## Rule 4 — prove it after

* `mix compile --warnings-as-errors` — catches now-unused aliases and imports
  the removal orphaned (this is how the dead `DiffLoader` alias surfaced).
* Run the suite. If a test now fails, decide honestly which is stale: **the code
  or the test.** A test asserting the behavior you just removed may be encoding
  a decision worth more than your change — that's Rule 1 wearing different
  clothes.
* Load a route that used the removed thing and confirm it still renders.
