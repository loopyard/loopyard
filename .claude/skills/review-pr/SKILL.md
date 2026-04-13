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
