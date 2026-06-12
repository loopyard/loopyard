# Workstations — your dev box, copied per branch, run by agents

**The whole idea, in one sentence:** a *workstation* is just a Docker **image**
(your tools) + a **`$HOME` volume** (your dotfiles, logins, env). An *agent* is a
container booted from that image with your `$HOME` mounted and a branch's code
mounted. So an agent **is a copy of your dev box, on a branch.**

The reason this feels right is that **it's almost entirely *not* Loopyard's
invention** — it's 40 years of Unix conventions (`$HOME`, dotfiles, the image,
the shell). We don't build a credential vault, a config DSL, or a per-tool
integration layer. We give agents your home directory and your tools.

> Supersedes `plans/credentials-and-users.md` — that content is folded in here
> under the workstation framing.

---

## What's an agent (concretely)

An **agent machine** = a container made of three things:

1. **Your workstation image** — apt/system packages, system tools, the base OS.
2. **Your `$HOME` volume** — dotfiles, env (`.bashrc`/`.profile`), and every
   tool's login files (`~/.config/gh`, `~/.claude`, `~/.fly`, `~/.aws`, …).
3. **The branch's code volume** — mounted at `/workspace`.

…with a **harness** (Claude/Codex via ACP, see #3) running on top. Branching a
repo stamps out a fresh machine like this on the new branch's code. You, your
agents, and any teammates who jump in all work on the **same** branch-machine
(the screen-share model) — not copies.

---

## The three layers (the persistence model — the core mental model)

| Layer | Carries | Persists? | Change it via |
|---|---|---|---|
| **Image** | apt/system packages, system tools, base OS | ✅ durable + **reproducible** | edit the workstation Dockerfile → rebuild (cached, seconds) → respawn |
| **`$HOME` volume** (mounted) | dotfiles, env, **logins/creds**, user-space tools (`~/.local`, `mise`/`asdf`) | ✅ durable + **live** | just edit it — instant in every agent, no rebuild |
| **code volume** (mounted) | the branch's code | ✅ | git |
| **container writable layer** | anything `apt install`'d **at runtime** | ❌ **ephemeral** | scratch only — gone on respawn |

The rule for "where does X go?": **system stuff → the image** (baked,
reproducible, needs a rebuild). **Your stuff → `$HOME`** (live). Runtime
installs are **scratch.**

**Runtime installs disappear by design, and that's a feature.** A root harness
can `apt install` at runtime to *experiment*; the keepers get **promoted into
the workstation Dockerfile** (the source of truth), which keeps machines
reproducible — cattle, not pets. Persisting every runtime FS change would give
you a snowflake you can never rebuild. (For something you want live *and*
persistent without a rebuild, install into `$HOME` — `~/.local/bin`,
`mise`/`asdf`, etc.)

---

## Credentials = `$HOME` (there is no vault)

Almost every CLI stores its login as a **file under `$HOME`**:

`gh` → `~/.config/gh/hosts.yml` · `claude` → `~/.claude/.credentials.json` ·
`fly` → `~/.fly/config.yml` · `aws` → `~/.aws/credentials` · `npm` → `~/.npmrc` …

So the "credential store" is **just those files on the `$HOME` volume.** No
Loopyard vault, no encryption layer, no per-tool plumbing — the tools don't know
Loopyard exists; they read `$HOME` like they always do.

- **Log in once** on your workstation (each `…login` writes to `$HOME`). Mount
  that `$HOME` into every agent → they have **all** your logins.
- **It's a live mount, not a baked copy** → re-auth a token once and every agent
  sees the new one instantly. (And OAuth CLIs auto-refresh, so you rarely even
  do that.)
- **Route, don't extract.** Never copy tokens out of `$HOME` into some store —
  run the command *in a container that mounts the home*. The harness reads
  `~/.claude` directly (which is why the harness must run *in the container* —
  ACP, #3 — not host-side).

### Own-account login, not provisioned API keys (the ToS reason)

Users authenticate with **their own** GitHub/Anthropic accounts via the official
CLIs (`gh auth login`, `claude` login). They're the customer; Loopyard is the
box. This is more ToS-aligned for an end-user product than "go get an API key,"
which drags users into the developer/commercial relationship. API key = fallback
only.

> ⚠ **ToS gate (before the multi-user product step):** own-sub-in-own-container
> is clearly fine (devcontainers/Codespaces do it); a multi-tenant server
> orchestrating *many* users' subs headless is grayer. Verify against Anthropic's
> terms before betting the product on it. GitHub device-flow login is fine.

---

## Env + setup = `.bashrc` / `.profile` (the shell, not a config system)

Env vars, PATH, aliases, `mise`/`nvm` activation — all the normal dotfile stuff,
on the `$HOME` volume. **One gotcha:** `.bashrc` runs for *interactive* shells,
`.profile` for *login* shells, and a plain `docker exec` is **neither**. So:

> **Run agent commands and spawn the harness through a login shell** —
> `bash -lc "…"` — so the home's init scripts actually source. Otherwise env vars
> set in `.bashrc` silently don't apply to non-interactive invocations.

---

## Capabilities = which logins a workstation has

A workstation's *powers* = **what it's logged into.** A `fly` binary is harmless
without `fly auth`. So:

- **"my dev box"** — logged into `gh` + `claude` → can write, commit, push. No
  Fly login → **literally can't deploy.**
- **"my deploy box"** — logged into `fly` → can ship.

Capability scoping = **which workstation an agent runs on.** Least-privilege for
free: an agent on the dev box has no prod keys to steal or misuse. **Deploy is a
gated, boundary-crossing op** (an approval card, like fork/integrate). For now,
**bake Fly into the one workstation**; splitting out a dedicated deploy machine
later is pure config (make a second workstation with only Fly, drop Fly from the
dev one) — **zero architecture change.**

---

## One origin per project (the git topology)

A project has exactly **one origin**: **GitHub** if connected, else a **local
bare repo** (the "internal repo"). The workstation's `git`/`gh` talks to that
origin — **one path**, like a laptop. The internal repo isn't a competing
source of truth; it's literally "the origin, for projects without GitHub yet."
Connect GitHub later → the local origin pushes up once → GitHub takes over.

It exists at all because **isolated branch-machines need a shared meeting point
to merge through** (A pushes, main pulls, they meet at the origin). Worktrees
can't do that (they need one shared filesystem → breaks the per-branch
isolation). For a GitHub project the origin is GitHub (± an invisible local
mirror for clone speed — plumbing you never think about).

`gh` is **install-once** (in the workstation image) + **auth-once** (in the
`$HOME` volume) → every branch-machine inherits both. Never per-machine.

---

## Users = profiles, not OS users

**"Brad Gessler" is a Loopyard profile** — `{id, name, email}` + *which `$HOME`
volume to mount* — **not** a Linux user. The harness can run as root; "being
Brad" just means Brad's `$HOME` and git identity are mounted in. No
accounts/passwords/DB; profiles live in `~/.loopyard/users.json` (like
`canonical_projects.json`). BasicAuth/LAN is the access gate; the profile is
"who am I driving as." Pre-fill name/email from the host's `git config` on first
run. MVP = just your profile; multi-user is additive.

---

## Security: root in a **sealed** container

The harness likely runs as **root** (base image has no `USER`; `docker exec`
defaults to root). That's fine **only if the container is sealed**, and the seal
— not the uid — is what provides isolation:

- ✅ **Sealed** = no Docker socket mounted, **not** `--privileged`, no sensitive
  host paths bind-mounted. Blast radius = *just this container* = the sandbox
  doing its job.
- ❌ **The one fatal mistake:** a root container with a path to the **Docker
  daemon** (socket mounted / host docker) → it can spawn privileged containers
  and escape to the host. **Agent containers must have no access to Docker.** The
  *server* manages Docker; agents never touch it.

**Hardening for later** (before untrusted code / multi-user): `USER agent`
(non-root, `$HOME=/home/agent` — the model just shifts the mount point), drop
Linux capabilities, never `--privileged`.

---

## Credential hardening path (Level 0 → broker)

- **Level 0 (now):** raw login files in `$HOME`; the agent can read them. Fine
  for your own agents on your own box.
- **Future:** inject **disposable / short-lived scoped tokens** so the agent
  never holds the master credential (like SSH-agent forwarding, or an LLM
  gateway). The **seams already exist for free**, so this is a drop-in later with
  zero agent-side change:
  - git → the **credential helper** (`gh auth setup-git` already sets one up)
  - Anthropic → `ANTHROPIC_BASE_URL` (point the harness at a proxy)
  - Fly → `FLY_API_TOKEN` env · AWS → `credential_process`
- It's **per-tool, opt-in, and only for the scary creds** (deploy/prod). Don't
  build it now; just keep the seams (helper + base URL) deliberate.

---

## Lifecycle nuance

A **server restart** should **restart** (preserve) the work container, *not*
recreate it — so an agent's scratch installs survive a bounce. Only an **image
change** should force a recreate (and that's exactly when "put it in the
Dockerfile" is the right answer anyway).

---

## Doing it the Unix way (the foot-guns we refuse to step on)

The whole bet is "lean on Unix, don't reinvent." That only pays off if we're
*disciplined* about it. The rules — and the face-shot each one prevents:

- **Respect `$HOME` + XDG; never hardcode `/root`.** Everything keys off `$HOME`
  (and `$XDG_CONFIG_HOME`/`$XDG_DATA_HOME`/`$XDG_CACHE_HOME` where tools use them);
  mount the home volume at `$HOME`, whatever it is. → *Avoids:* welding the model
  to root. The day we run non-root, `$HOME` just moves `/root`→`/home/agent` and
  the mount follows — nothing breaks. Hardcode `/root/.config` and you can't.
- **One uid everywhere a `$HOME` is mounted.** Every container mounting a given
  home runs as the *same* uid (root now, or a fixed `agent` uid later, but
  consistent). → *Avoids:* uid 0 and uid 1000 sharing one volume = permission-
  denied hell on the creds/dotfiles.
- **Perms like a grown-up:** home `0700`, secrets `0600` (gh/claude already do
  this — don't undo it). → *Avoids:* world-readable tokens on a shared volume.
- **Env/PATH in `.profile`, sourced via a login shell** (`bash -lc`). → *Avoids:*
  `.bashrc`-only env silently vanishing under non-interactive `docker exec`.
- **Proper PID 1.** Run containers with an init (`tini` / `docker --init`) so the
  harness isn't PID 1 and its children (`apt`, `git`, builds) get reaped and
  signals forwarded. → *Avoids:* zombie pileups and `SIGTERM` not stopping the
  agent cleanly.
- **A real seal, not "we think it's isolated":** `--cap-drop=ALL` (add back only
  what's needed), `--security-opt=no-new-privileges`, **no Docker socket**, never
  `--privileged`, read-only rootfs where feasible (the writable bits are the
  mounted volumes). → *Avoids:* "root is fine, it's isolated" turning out to mean
  a mounted `docker.sock` and a one-command host escape.
- **Compose tools; don't reinvent them.** Creds = the CLIs' own files. Auth
  indirection = git's *credential helper* + `ANTHROPIC_BASE_URL`. Branch/merge =
  git's real remotes + bare repos. → *Avoids:* a bespoke vault / config DSL / sync
  engine that drifts from the tools and rots.
- **Plumbing, not screen-scraping.** When the *server* talks to git/gh, use
  plumbing + structured output (`git` plumbing, `gh --json`), never parse human
  text. → *Avoids:* a cosmetic `gh` change silently breaking the control plane.
- **The Dockerfile is the source of truth; the rootfs is disposable.** → *Avoids:*
  snowflake pets you can never rebuild.

**The razor:** if a change can't be expressed as *a file in `$HOME`*, *a line in
the Dockerfile*, or *a git remote*, that's the smell that we're about to reinvent
something Unix already does — stop and go find the existing mechanism.

## How it maps to today's code

- `WorkContainer` + `priv/workspace-base/Dockerfile` → the **workstation image**
  (already ships git/gh/ssh/node/claude-code-acp). Becomes the per-user/personal
  base; project deps layer on via the workspace Dockerfile.
- ACP (#3) → the harness in the container, reading `~/.claude` — the prerequisite
  for "route, don't extract" and for the `$HOME`-creds model.
- `CanonicalRepo` → the **local-bare origin** (no-GitHub) / GitHub sync.
- `Tools.Container.Git` hardcodes `loopyard@local` → source identity from the
  driver's profile / mounted `~/.gitconfig`.
- `Onboarding` → load `users.json`; pre-fill from host `git config`.
- New: the **per-user `$HOME` volume** lifecycle; mount it (+ run via `bash -lc`)
  into work + transient-git containers; a "manage my workstation" console.

---

## Build order (and how it maps to epic #21)

1. **Layer 1 — self / host-sourced (smallest, unblocks you today):** git
   authorship from real identity (#31); host-sourced creds → harness/git
   injection (#22). No new UI.
2. **Layer 2 — workstations:** the workstation **image** lifecycle (apt /
   promote-to-Dockerfile / login-shell env); the per-user **`$HOME` volume**
   (#24); profiles (#23); own-account login surfaced in-app (#25/#26); origin =
   GitHub-or-local + control-plane git acts as the user (#27); agent ownership
   (#28); new-project-from-GitHub (#29). **(ToS gate here.)**
3. **Layer 3 — hardening:** sealed container audit (no Docker socket) + non-root
   `USER`; the disposable-token broker on scary creds; deploy as its own
   machine/gated op; API-key fallback; co-authorship; disk encryption (#30).

---

## Decided / non-goals

- **Workstation = image + `$HOME` volume.** Not a Loopyard config system — Unix.
- **Creds = files in `$HOME`.** No vault, no encryption layer, no extraction —
  mount and route.
- **Own-account login, not provisioned keys** (ToS); one driver per session
  (multiplayer = screen-share, not key-sharing).
- **Capabilities = which logins;** deploy is gated; one fat workstation now,
  split later (config, not rework).
- **Root + sealed now; non-root + broker later** — proportionate, not dogmatic.
- **Cattle, not pets:** the Dockerfile is the source of truth; runtime installs
  are scratch.
- Naming: "workstation" vs "workspace" is close — tighten before shipping.
