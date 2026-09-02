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

## Workstation = identity (decided 2026-06-14)

A workstation is **a person's identity**, not a per-purpose box. `brad`, `jamie` —
each is one workstation = {id, their Dockerfile/image, their logins in the home
volume, their env}. **Profile, user, and workstation collapse into one concept.**

- You **operate as** a workstation (a lightweight identity selector on entering
  Loopyard — featherweight login). Agents you spin up **inherit** it: your image,
  your creds, your name on commits.
- This **solves "which image does the agent use"**: it doesn't ask — it follows
  the driver's identity. No per-agent pick, no default/pin machinery, no
  dev/deploy split (your workstation holds your whole identity).
- Multiplayer = "one driver, their logins": brad's agents run as brad, jamie's as
  jamie. An agent is owned by its spawner and runs on that identity.

Dir structure (Phase 2): `<LOOPYARD_HOME>/workstations/<id>/` (Dockerfile, env.json,
workstation.json{label}); Docker holds `loopyard-ws-<id>` image + `loopyard-ws-<id>-home`
volume. Today's singleton becomes one entry. Image/Env/Integration modules go from
"the workstation" → "workstation `<id>`"; UI/MCP operate per-id, defaulting to the
operating-as identity.

## `current` is UI-only; headless names the workstation (decided 2026-06-14)

A server-global `current` that *headless* callers silently inherit is spooky
action at a distance — a `mix`/`rpc`/MCP call would operate on whatever the UI
last clicked, with no trace in the call. So:

- **`Loopyard.Workstation.current/0` survives, but only the *UI* reads it.** The
  nav switcher + Workstation page set/read it (a file: `<HOME>/workstations/.current`).
- **`Image`/`Env`/`Container` take a *required* `id` — no `\\ current()` default.**
  Removing the default is the enforcement: a headless caller physically cannot
  inherit the global; it must pass an id. The UI resolves `current()` once at its
  boundary (mount / event handler) and threads it down.
- **HTTP push names the workstation in the URL:** `/workstation/:ws/{setup.sh,env,file}`.
  A curl always says which identity; unknown id → 404. The page bakes your current
  id into the command it shows, so copy-paste is unchanged. (`:tool/docs.md` stays
  identity-agnostic.)
- **Sanctioned `current()` reads** (explicit, greppable — not hidden defaults): the
  two LiveViews, the workstation-management agent + its tools (it configures
  whatever you're operating as), and `WorkContainer.recreate` (the agent-boot stamp
  point — a future refinement stamps the identity onto the workspace at create time
  so even headless boots are deterministic).

## MCP + HTTP parity (Phase 1, building first)

Every capability is **one handler, two doors**: an HTTP route AND an MCP tool call
the same function. Per the decision above, the MCP tools take a **required**
`workstation_id` (headless = always explicit) — no defaulting to a server global.
Tools: `list_integrations`, `read_integration`, `set_env`, `push_file`,
`workstation_status`, `restart`, maybe `run_console`. Gated by `PushToken`. HTTP
twins already exist for env/file/docs; complete the set. So: tell an agent "set up
workstation brad," or curl it.

## Notes

- Route precedence: the `/workstation/:ws/{setup.sh,env,file}` push routes +
  `/workstation/:tool/docs.md` are distinguished by their literal trailing segment;
  `/workstation/switch/:id` + `/workstation/create` are 2-seg literals. The bare
  `/workstation/:tool` integration page is last so it can't shadow the deeper routes.
  Phoenix matches in **definition order** — verify with `mix phx.routes`.
- Status checks hit the container (exec) — do them async per page, not inline.
- File-based creds land in `$HOME` (live, no restart); env tokens need a Restart.
