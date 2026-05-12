---
name: new-feature
description: Build a new feature with proper isolation, tests, and multiplayer support
user_invocable: true
---

# New Feature

Build features the right way: isolated module first, tests first, then integrate.

## Context

Dev environments run in Docker containers. Agents exec into containers via MCP tools. File changes go through Docker volumes, not the host filesystem. Tests that touch agent behavior should verify operations go through `Docker.exec_in` or `VolumeIO`.

## Step 1: Plan the boundary

Before writing any code, answer:
- **What module does this logic belong in?** If it's going in a LiveView private function, stop. Extract it.
- **Does this need to be multiplayer?** If other viewers should see the change, it must go through GenServer → PubSub → all LiveViews. Never modify shared state in assigns directly.
- **What are the inputs and outputs?** Define the public API before implementation.

Write your plan as a comment in the chat. Get alignment before coding.

## Step 2: Write failing tests

Write the tests FIRST. Not after. Not "I'll add tests later." Now.

- **Unit tests** for the isolated module. Cover boundary conditions, not just happy paths.
- **Integration tests** if the feature touches the websocket/channel/PubSub stack. Test the real path, not a mock of it.
- **Multiplayer tests** if applicable. Spin up N subscribers, have each interact, assert each sees the correct state exactly once.

Run the tests. Watch them fail. This proves the tests actually test something.

## Step 3: Build the isolated module

Write the module. It should:
- Live in `lib/loopyard/` (infrastructure) or `lib/loopyard_web/components/` (UI components)
- Have a clear public API with `@doc` strings
- Accept injected dependencies where needed for testing (e.g. Terminal accepts a `cmd` option so tests use a local shell instead of Docker)
- Have zero coupling to LiveView assigns or socket

Run the tests. Watch them pass.

## Step 4: Integrate into the app

Wire the module into the LiveView, controller, or channel that needs it. The LiveView should be thin: handle events, delegate to the module, render.

If this is multiplayer:
- State changes go through GenServer, which broadcasts via a **publisher module** in `lib/loopyard/events/` (not raw `Phoenix.PubSub.broadcast`). Add a struct + `publish/1` clause to the relevant `Loopyard.Events.<Topic>` module.
- LiveView declares `@behaviour Loopyard.Events.<Topic>.Subscriber`, implements every `on_*` callback, and dispatches from `handle_info(%Events.Struct{} = e, socket)` to the callback.
- Verify: open two browser tabs, make a change in one, see it in the other. Use `/system/events` to see the broadcast timeline if something isn't arriving.

## Step 5: Verify

- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test --exclude docker` passes
- [ ] New module has its own test file
- [ ] Multiplayer works (if applicable)
- [ ] No logic buried in LiveView private functions
- [ ] Update CHANGELOG.md
