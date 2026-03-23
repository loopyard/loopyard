## What changed

<!-- Brief description. What does this PR do? -->

## How to test

<!-- Steps to verify, or "see tests" if covered -->

## Checklist

- [ ] Tests added/updated (every feature needs tests, every bug fix starts with a failing test)
- [ ] Logic is in modules, not LiveView private functions
- [ ] Shared state goes through GenServer → PubSub (not direct assign)
- [ ] Works with multiple viewers (multiplayer)
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test --exclude docker` passes
