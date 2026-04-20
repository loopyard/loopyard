---
name: review-pr
description: Review a PR against the project's code rules
user_invocable: true
---

# Review PR

Check the PR against the rules in CLAUDE.md. These rules exist because we shipped bugs when we broke them.

## Read the diff

Read every changed file. Understand what the PR does before checking rules.

## Check: Tests

- Does every new feature have tests?
- Does every bug fix include a test that reproduces the bug?
- Are the tests testing behavior (logic, data flow, multiplayer) or just rendering (HTML structure)?
- Do tests exercise the real path or just an isolated layer?

If there are no tests, the PR is not ready.

## Check: Module isolation

- Is there logic in LiveView private functions that should be in its own module?
- Signs to look for: data transformation, accumulation, windowing, complex conditionals, pattern matching with 5+ clauses
- Good: `StreamBuffer.append(buf, data)` called from LiveView
- Bad: 20-line `defp upsert_stream_message` inside chat_live.ex

## Check: Shared state

- Does any `handle_event` modify shared state (messages, agents, service_statuses) directly in assigns?
- If yes, it's broken for multiplayer. The change must go through GenServer → PubSub.
- Local-only assigns are fine for per-viewer state (which tab is open, whether an input is expanded).

## Check: PubSub topics

- If adding a new PubSub topic, does it collide with any Phoenix channel topic?
- Channel topics and GenServer broadcast topics must be distinct strings.
- Pattern: `"terminal:#{id}"` for channel, `"terminal_output:#{id}"` for broadcasts.

## Check: Publisher modules + subscriber behaviours

Coordination hardening (Moves #2 + #3) wired a compile-time contract around broadcasts. New broadcast code must follow it.

- Does any `.ex` file outside `lib/boom_looper/events/` call `Phoenix.PubSub.broadcast`? That's a boundary violation; `test/boom_looper/pubsub_boundary_test.exs` would fail. Route through a publisher module.
- If the PR adds a new event shape, it should be a struct in `BoomLooper.Events.<Topic>` with a `publish/1` clause. Tuple-shaped broadcasts are forbidden.
- If a LV subscribes to a topic, does it declare `@behaviour BoomLooper.Events.<Topic>.Subscriber` AND implement every `on_*` callback? There are no `@optional_callbacks`; missing callbacks emit compile warnings.

## Check: Retry + resources + ETS

- Any new `Process.sleep` inside a `handle_info`? That's a mailbox-blocking regression. Use `Process.send_after` + a separate handle_info clause. For async backoff math use `BoomLooper.Retry.backoff_ms/2`.
- Any new `Process.sleep` elsewhere inside a retry loop? Use `BoomLooper.Retry.run/2`.
- Any new `:ets.new`? StateKeeper is the sole owner; add your table to its `@tables` list instead.
- Any new `Process.link` / ad-hoc cleanup for a resource that should die with its owner? Use `BoomLooper.Resources.track/4` so the Janitor releases it on DOWN (and it shows up in `/system/orphans` if it ever leaks).

## Check: Multiplayer

- Can two browser tabs see the same state?
- If one tab makes a change, does the other update?
- If someone joins late, do they see the current state?
- If someone clears/resets, does everyone see it?

## Check: Docker boundary

- Do any changes leak host filesystem access? Agent tools must go through `Docker.exec_in` or `VolumeIO`, never host `File` operations.
- Are new tools properly using `Helpers.truncate_for_agent` for bounded output?
- Do file operations stay within the Docker volume (`/workspace`), not the host?

## Check: Complexity

- Does the feature require the user to install something, run sudo, or configure anything?
- If yes, can it be simpler? The app should work with `mix boom.setup && mix boom.server`.
- Are there toggles or config that should just be on by default?

## Check: Compilation

```bash
mix compile --warnings-as-errors
mix test --exclude docker
```

Both must pass.

## Output

Summarize findings as:
- **Must fix** (blocking): missing tests, broken multiplayer, shared state bypass
- **Should fix** (non-blocking): extraction opportunities, naming, docs
- **Nice to have**: style, organization
