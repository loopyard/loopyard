---
name: fix-bug
description: Fix a bug by reproducing it in a test first, then fixing
user_invocable: true
---

# Fix Bug

Never ship a fix you haven't verified. Reproduce it in a test first.

## Step 1: Reproduce

Write a test that demonstrates the bug. The test must FAIL before you fix anything.

If the bug is in the UI/websocket/channel stack, write an integration test that exercises the real path. We've shipped "fixes" for terminal double-echo three times because unit tests passed while the integration was broken. The fix that actually worked was proven by `terminal_integration_test.exs` which connects via the channel, sends input, and asserts output appears exactly once.

If you can't reproduce it in a test, you don't understand the bug yet. Keep investigating.

**Debug tip:** Use IEx remote shell to inspect live state:
```bash
iex --sname claude --remsh boom@$(hostname -s)
```
Then inspect ETS, GenServers, etc: `:ets.tab2list(:project_registry)`, `BoomLooper.ChatAgent.list_agents()`.

## Step 2: Run the test, watch it fail

```bash
mix test path/to/test.exs:LINE
```

If it passes, your test doesn't reproduce the bug. Go back to step 1.

## Step 3: Fix the code

Make the smallest change that fixes the bug. Don't refactor, don't improve, don't clean up nearby code. Just fix the bug.

## Step 4: Run the test, watch it pass

```bash
mix test path/to/test.exs:LINE
```

If it fails, your fix doesn't work. Go back to step 3.

## Step 5: Run the full suite

```bash
mix test --exclude docker
```

Make sure you didn't break anything else.

## Step 6: Check multiplayer

If the bug involved shared state, PubSub, or anything multiplayer:
- Did the fix use the shared path (GenServer → PubSub → all LiveViews)?
- Or did it add a local-only workaround that other viewers won't see?

Common traps:
- Adding optimistic local state that skips PubSub
- Using the same PubSub topic string as a Phoenix channel topic
- Swallowing errors with rescue that hide the real problem

## Step 7: Verify

- [ ] Test fails before fix, passes after
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test --exclude docker` passes
- [ ] Update CHANGELOG.md
