# Workstation integrations — per-tool setup, docs for humans & agents

## The shape (decided with Brad, 2026-06-14)

After a long thrash through "everything is an env var," the honest conclusion:
**each tool wants its own setup.** GitHub = `gh auth login` in the console;
Claude/Codex = curl a credential *file* up; Fly = a token env var. So model each
integration as **its own thing** with **its own page, its own doc, its own
method** — not one universal mechanism.

```
/workstation                 index — cards per tool, "connected / not", links in
/workstation/:tool           a page per tool: its doc + setup widget + status
/workstation/:tool/docs.md   raw markdown an AGENT can fetch (same source)
```

## Hard requirements

1. **Agents work with NOTHING set up.** Integrations are additive — empty store →
   no `-e`, container still boots, agent runs (chat agent uses host Claude auth).
   Verified. Never make an integration required.
2. **Click into each thing to add it.** The index links out to `/workstation/:tool`.
3. **Easy to add** — for the user (follow the tool's doc), and for us (a markdown
   file + a few lines of data, not plumbing).
4. **Two on-ramps:** a script you run on your Mac (`setup.sh`, already built) OR
   click into a tool and follow its page.

## The primitive we already have (the substrate)

The per-tool pages just *compose* what's built:
- env push   `PUT /workstation/env/:key`   → `Workstation.Env` → injected at boot
- file push  `PUT /workstation/file/*path` → `Container.write_file` → live in `$HOME`
- console    `Terminal.send_input` (▶ Run a command in the shared console)
- script     `GET /workstation/setup.sh` (all-in-one)
- auth       `PushAuth` (local = no token, tunnel = `PushToken`)

## The abstraction

`Loopyard.Workstation.Integration` — a registry. Each entry is **data**:

```elixir
%{
  id: "github", label: "GitHub",
  method: :console,                    # :console | :file | :env
  console: "gh auth login",            # for :console — run in the embedded terminal
  file: ".codex/auth.json",            # for :file — push from ~/<file>
  env: "FLY_ACCESS_TOKEN",             # for :env — token env var
  mac: "fly auth token",               # the Mac command that prints the token (for :env)
  connected_check: ...,                # cheap "is it set up?" probe
  doc: "github"                        # priv/integrations/github.md
}
```

Adding a tool = a `priv/integrations/<id>.md` + one map entry.

## Docs for humans AND agents (the keystone)

`priv/integrations/<id>.md` is the single source of truth — written so a person
*or* an LLM can follow it. Served two ways from the same file:
- the LiveView renders it (markdown → the existing `Markdown` hook),
- `/workstation/:tool/docs.md` (and later an MCP `read_integration` tool) returns
  the raw markdown so an agent can read "how do I wire GitHub in this box" and
  either do it or walk the user through it.

## Build order

1. `plans/integrations.md` (this).
2. `Workstation.Integration` registry + markdown loader + `connected?/1`.
3. `priv/integrations/{github,claude,codex,fly}.md`.
4. `WorkstationToolLive` + route `/workstation/:tool` (+ `/docs.md`): renders the
   doc, the method's setup widget (▶ Run / 📋 Copy / paste), async status, and the
   embedded console for `:console` tools.
5. Index: the "Connect your tools" panel → cards that link to `/workstation/:tool`
   and show connected/not. Keep the all-in-one `setup.sh` callout.

## Notes

- Route precedence: `/workstation/setup.sh` (static) must win over
  `/workstation/:tool` (dynamic). Phoenix matches static before dynamic — verify.
- Status checks hit the container (exec) — do them async per page, not inline.
- File-based creds land in `$HOME` (live, no restart); env tokens need a Restart.
