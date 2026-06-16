# Agent home + the workstation pump

How an agent boots its environment, how identity/creds get into it, and how we
propagate a change to running agents. Decided across a long design session
(2026-06-08 → 06-15). **This supersedes the earlier "one container in the
project's compose is the agent" framing — don't re-derive that.**

## The one-line model

> **agent = image (tools) + `/home/<name>` volume (you) + `/workspace` (code),
> launched with a login shell.**

Three inputs, each owning exactly one job. They never overlap, so the mental
model never tangles:

| input | owns | scope | mechanism |
|---|---|---|---|
| **image** | the tools (ruby, node, gh, git, the harness) | per project (shared) | a Dockerfile |
| **`/home/<name>` volume** | *you* — creds, dotfiles, env | per seat (per person) | a named Docker volume |
| **`/workspace`** | the code | per branch | a named Docker volume |

Run the container as user `<name>` so `$HOME=/home/<name>` falls out naturally
(non-root is also more secure). Launch via a login shell (`bash -lc 'exec
<harness>'`) so `~/.profile` is always sourced.

## Identity is a named volume — the durable noun

The thing worth modeling, persisting, versioning, mounting, and counting agents
against is the **home volume**: `loopyard-home-<name>` (e.g.
`loopyard-home-brad`). It is pure storage in Docker's Linux VM. Nothing runs for
it to exist.

- **Named volume, never a host bind mount.** Host binds on macOS go through Docker
  Desktop's FS translation (slow) and re-open the host-filesystem hole the sandbox
  exists to close. Named volumes are native ext4 in the VM — fast, portable,
  host-decoupled. (Same as code: `loopyard-<workspace_id>-code`.)
- **id → volume is a one-line convention.** Identity `brad` ↔ volume
  `loopyard-home-brad`. The workstation registry holds the map.

## The "workstation" = a disposable shell over the home volume

There is **no workstation _entity_.** A workstation is a **throwaway container with
the seat's home volume mounted at `$HOME`, giving you a shell.** You log in and set
up creds — interactively (`gh auth login`, `vim ~/.gitconfig`, paste a token) or
via the pump scripts (curl creds up from your Mac). Exit and the container is gone.

**The only thing that matters is the VOLUME.** The shell is a disposable handle on
it. The rule that makes it bulletproof:

> In the workstation shell, changes to `/home/<name>` **persist** (they're the
> volume). Changes anywhere else (`apt install`, `/tmp`, …) are **throwaway** (the
> container layer).

So `gh auth login` writes `~/.config/gh` → on the volume → every agent that later
mounts the volume inherits the login. Set up once, every agent has it.

- `/homes` = the list of home volumes (one per seat).
- `/homes/<name>` = a view onto **one** volume: its files, which tools are
  connected, and a "pump from my Mac" button. No services, no daemon, no lifecycle.

The word "workstation" collapsed all the way down: not a machine, not an identity,
not even persistent — it's **the little container that occasionally writes your
home volume.** The pump, made literal. The durable noun underneath it is the home.

## Secrets = files in the home volume, nowhere else

Every credential surface the world has collapses to **one** surface the container
sees: files under `$HOME`. Every Unix tool already agrees to look there.

- **File creds** (gh `hosts.yml`, aws `credentials`, ssh keys) → files at their paths.
- **Env vars** → `export` lines in `~/.profile`, sourced by the login shell. An env
  var is just a file.
- **Non-secret runtime config** (agent id, workspace id, `TERM`) → `docker run -e`.
- **Never** a secret in container config (`docker run -e SECRET=…`, visible in
  `docker inspect`) or in image layers (baked forever, shipped to registries).
- Dump *all* creds in regardless of installed tools — `~/.aws/credentials` with no
  `aws` present is a no-op. No per-agent cred curation.

**The membrane.** The world's mess (keychain, env, OAuth, files) lives entirely on
the **host-side intake** step, whose one job is to normalize everything into files
under `$HOME`. Downstream of that membrane the container model has *zero* per-tool
exceptions: a `$HOME` volume, mounted, sourced by a login shell. The dread came
from letting the intake mess leak into the container model — don't. One surface,
no exceptions.

## Multi-user / multi-workstation

The per-user axis is **which home volume you mount** — a one-line swap, not a
rebuild:

- Brad devs → mount `loopyard-home-brad`.
- Jamie devs → mount `loopyard-home-jamie`. Same image, same code, different `-v`.

No per-user image, no `--build-arg WORKSTATION=…` base. (The ARG base was the wrong
axis — per-user is *creds*, which are a mount; *tools* are shared, so the image is
shared.)

## dev = pet, test/staging/prod = cattle

Adding tools to a project does **not** mean swapping the agent for a fatter image.
The dev container is a **pet**: long-lived, mutable, grown in place. The agent
already has `exec` — it runs `mise install ruby`, `gem install rails`, `apt-get
install gh` into its **live** container. Nothing restarts; same agent throughout.

The Dockerfile is demoted to two smaller jobs: the **cold-start** point and the
**reproducibility record**. test / staging / prod are **cattle** — built fresh
from the Dockerfile every time, clean and reproducible. They keep each other
honest: if the agent installed rails live but forgot the Dockerfile, the next
**test** env (built from it) fails → the agent fixes the Dockerfile.

A real dev recreate is rare and deliberate (swap the base OS, or "bake" the
accreted state for fast cold starts) — and even then it's not a teardown:
`/home/<name>` and `/workspace` are volumes, the conversation resumes via the
crash-recovery path. Same agent, refreshed body.

> Caveat: for live-installed tools to survive even that rare restart, install into
> a persistent location (`~/.local`, a mise/tools dir, or the home volume), not the
> container's throwaway layer.

## Environments are per-branch and ephemeral (direction, not yet pinned)

Traditional envs break for a factory because they're *shared and long-lived*. A
factory runs many agents on many branches at once, so the model inverts to
**per-branch and ephemeral**, fanning into one real prod:

- **dev** — this branch's working cluster; where its agent iterates. The exec target.
- **test** — a clean run the agent dispatches (same image, fresh db,
  `RAILS_ENV=test`). Ephemeral, parallel-friendly (a factory fires tons of them).
- **staging** — this branch's preview URL. Shareable, ephemeral.
- **prod** — the one persistent, shared target everyone merges into. Out of the
  sandbox; a *deploy* axis, not an *exec* axis.

App services (db, redis, web) run via **compose, which Loopyard owns and authors**
in `.loopyard/workspace/` (a project's own `docker-compose.yml` is a *hint* for
generating ours, never the file we run). The agent is its **own Loopyard-run
container beside the cluster on a shared network** — not one of the compose
services. "Which service is the agent?" is a non-question: none of them. (The
exact dev/test boot + agent↔cluster networking is the next thing to pin when we
build it.)

## Versioning + tracking + refresh

**`home_version`** = content hash of the home volume's source. Free, and it dedups
(re-saving identical content doesn't bump it → no needless restarts). Each booted
agent records `{identity (home volume), home_version, image_ref}`.

**Tracking** — we must know which agents booted from which home + version, so a
change knows whom to touch and we can show the blast radius. An index over running
agents, queryable by `(identity, home_version)` → list + count; surfaced at
`/system` ("N agents on home v3 (current), M on v2 (stale)"). Reuse
`ChatAgentRegistry` + `StateKeeper` ETS; `Agent.Reconciler` keeps it honest.
**(Slice 1 landed: each agent is stamped with `workstation_identity`; `/system`
shows a per-identity count.)**

**Refresh policy** (home change → version bump → who's stale):
- **File cred change**: *live*. The mounted volume already has the new file; CLI
  tools re-read on next invocation. No restart for file-reading tools.
- **Env / `~/.profile` change**: the running harness sourced `.profile` once → it's
  stale. **Restart the harness** (re-source) — *not* recreate the container; the
  file is already live in the volume.
  - *Graceful (default):* at the next turn boundary (`stream_done → :idle`), restart
    with `resume:` — the existing crash-recovery / idle-reap path; conversation
    never breaks.
  - *Force:* immediate, interrupt the turn — for a revoked/rotated secret.
- **Image change**: recreate the container (new image); volumes + resume preserve
  everything.

## Build order

1. **Stamp + track + count.** Record each agent's `{identity, home_version,
   image}`; add the `/system` query + count. Pure observability. **(Slice 1 landed.)**
2. **Boot the agent from `image + /home/<name> volume + /workspace`**, running as
   user `<name>` with a login shell. Replace the per-identity workstation-image
   path; keep the home mount.
3. **Home versioning** (content hash) + the **stale trigger**.
4. **Graceful drain**: harness restart-with-resume at turn boundary on stale; force
   path for revocation.
5. **Concurrency**: when agents run concurrently on one identity, make the home
   volume a read-only *source* + copy-seed a per-agent writable home on boot
   (tighten perms: `chmod 600 ~/.ssh/*`). Only land this when concurrency actually
   forces it.

## Out of scope / deferred

- The **secret manager** beyond the pump — rotation, audit, scoping
  (identity ∪ project). The pump (`Integration.mac_script`, the file/env push
  endpoints) already populates the volume; richer management is later.
- The exact **dev/test environment boot** + agent↔cluster networking.
