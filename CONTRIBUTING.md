# Contributing to Loopyard

## Getting started

```bash
git clone https://github.com/loopyard/loopyard.git
cd loopyard
mix loopyard.setup    # installs deps, fixes Docker config, builds assets
mix loopyard.server   # starts the server
```

Requires macOS, Homebrew, Docker (OrbStack or Colima — not Docker Desktop), and a Claude API key.

## Development workflow

1. **Branch from main.** One branch per feature/fix.
2. **Write a failing test first.** Bug fix or new feature — red before green.
3. **Keep commits atomic.** One commit, one logical change. See [docs/GIT.md](docs/GIT.md).
4. **Run the suite before pushing.** `mix test` should finish in under 30 seconds.

## Code rules

Read these before writing code:

- **[CLAUDE.md](CLAUDE.md)** — Architecture overview, key modules, how things fit together
- **[docs/CODE_RULES.md](docs/CODE_RULES.md)** — Hard rules that prevent real bugs
- **[docs/TESTING.md](docs/TESTING.md)** — Test strategy, tags, contracts
- **[docs/GIT.md](docs/GIT.md)** — Atomic commits, sane messages
- **[docs/SECURITY.md](docs/SECURITY.md)** — Workspace boundaries, tool security

## Running tests

```bash
mix test                           # Fast suite (~30s, excludes Docker tests)
mix test --include docker          # Include Docker integration tests
mix test path/to/test.exs          # Specific file
mix test path/to/test.exs:42       # Specific line
```

## Quality checks

```bash
mix compile --warnings-as-errors   # No warnings
mix format --check-formatted       # Consistent formatting
mix credo --strict                 # Linter
mix deps.audit                     # Dependency CVEs
```

## Claude Code skills

If you use Claude Code, these skills are available:

- `/new-feature` — plan, test, build, integrate
- `/fix-bug` — reproduce in a test first, then fix
- `/review-pr` — check against project rules
- `/eval` — run setup evals

## Architecture

Loopyard is a Phoenix LiveView app with no database. State lives in ETS (runtime) and append-only ETF logs (persistence). Docker Compose manages dev environments. Claude Code agents run as GenServer processes.

The two biggest files are the GenServer reactor (`chat_agent.ex`) and the LiveView reactor (`workspace_live.ex`). Both follow the same pattern: thin message routing at the top, stateless logic extracted into focused modules.

See [CLAUDE.md](CLAUDE.md) for the full module map.
