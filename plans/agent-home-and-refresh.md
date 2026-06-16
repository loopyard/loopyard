# Agent home + credential refresh

How an agent boots its environment, and how we propagate a change to running agents.
Decided across a long design session (2026-06-15). This is the canonical model —
don't re-derive it into the "inject secrets into the container/image" version.

## Model

An **agent** = three composed inputs, not one machine:

- **project agent image** — the tools (rails, gems, node). Declared in git, written
  by the setup agent. One container in the project's compose is designated "the
  agent container." Reproducible, identity-agnostic, interchangeable across agents.
- **identity home volume** — mounted at `$HOME`. Creds + dotfiles + `~/.profile`.
  This *is* the credential surface. Image-agnostic — mounts onto any base image.
- **branch code** — at `/workspace`.

Launched with a **login shell** (`bash -lc 'exec <harness>'`) so `~/.profile` is
sourced.

Drop the per-identity *workstation image* (`loopyard-ws-<id>:latest`) — baking
identity into a machine image was the skeuomorph. Identity = the home volume only;
toolchain = the project image.

### Secrets live in the home volume, nowhere else

- **File creds** (gh `hosts.yml`, aws `credentials`, ssh keys) → files at their paths.
- **Env vars** → `export` lines in `~/.profile` (also just a file). Sourced by the
  login shell.
- **Non-secret runtime config** (agent id, workspace id, `TERM`) → `docker run -e`.
- **Never** a secret in container config (`docker run -e SECRET=…`, visible in
  `docker inspect`) or in image layers (baked forever, shipped to registries).
- Dump *all* creds in regardless of installed tools — a `~/.aws/credentials` with no
  `aws` present is a no-op. No per-agent cred curation.

### Scope = a second mount

- **identity volume** — per seat (your gh/Claude). Follows you across projects.
- **project volume** — per repo (deploy key, SA json, `DATABASE_URL`). Shared by
  every agent on the project.

Both mounted/seeded into the same `$HOME` → composed.

## Boot

```
docker run -d \
  -v <identity-home>:/root \        # creds + dotfiles + .profile
  -v <project-creds>:/seed/proj:ro \ # (or merged into /root)
  -v <branch-code>:/workspace \
  -e LOOPYARD_AGENT_ID=… \          # non-secret runtime only
  <project-agent-image> \
  bash -lc 'exec <harness>'
```

- **Single agent per identity:** mount the home volume RW at `/root`. Simplest.
- **Concurrent agents on one identity:** the home volume is a read-only *source*;
  the entrypoint `cp -a /seed/. /root/` into a per-agent writable home (tighten
  perms: `chmod 600 ~/.ssh/*`). Start with mount; add copy-seed when concurrency
  actually lands — it's the only thing that forces it.

## Versioning

`home_version` = content hash of the identity (+ project) home **source**. Free,
and it dedups: re-saving the same content doesn't bump it → no needless restarts.

Each booted agent records `{identity, home_version, image_ref}`.

## Tracking (the operational requirement)

We must know **which agents booted from which home + env**, so a change knows who
to touch and we can show the blast radius.

- An index over running agents, queryable by `(identity, home_version)` → list + count.
- Surface at `/system`: "N agents on home v3 (current), M on v2 (stale)."
- Reuse `ChatAgentRegistry` + `StateKeeper` ETS to stamp each agent's boot config;
  `Agent.Reconciler` keeps the index honest against reality.

## Refresh policy (home change → version bump → who's stale)

- **File cred change** (mounted model): *live*. The mounted container sees the new
  file; CLI tools re-read their config on the next invocation. Note it; no restart
  needed for file-reading tools.
- **Env / `~/.profile` change**: the running harness sourced `.profile` once at
  start → it's stale. **Restart the harness** (re-source) — *not* recreate the
  container; the `.profile` file is already live in the volume.
  - *Graceful (default):* at the next turn boundary (`stream_done → :idle`), restart
    the harness **with resume** — the exact `restart_session` + `claude_session_id`
    path that already handles crash recovery / idle reap. Conversation never breaks.
  - *Force:* immediate, interrupt the turn — for a **revoked/rotated** secret.
- **Image change**: recreate the container (new image).
- **Copied-home model:** any change → re-seed → restart harness (no live FS).

The hard part — "stop the harness, restart it, resume the conversation seamlessly"
— already exists for crashes and idle reaps. "Pick up the new home" is the same
operation with a new trigger (home_version stale) + a re-seed step.

## Build order

1. **Stamp + track + count.** Record each agent's `{identity, home_version, image}`;
   add the `/system` query + count. No behavior change — pure observability. This is
   the new requirement, and it's self-contained.
2. **Point the agent container at the project image** + mount the identity home
   (replace the workstation-image `WorkContainer` path; keep the home mount we built).
3. **Home versioning** (content hash) + the **stale trigger**.
4. **Graceful drain**: harness restart-with-resume at turn boundary on stale; force
   path for revocation.
5. **Copy-seed** for concurrency — only when we run agents concurrently on one identity.

## Out of scope / deferred

- The **secret manager** UI (control plane that renders secrets → files in the home
  volume, scoped identity ∪ project, rotate/audit). It's the populator of the home
  volume; not required to land the boot model. See the credential-transfer work
  already shipped (`Integration.mac_script`, the file/env push endpoints).
