# Credentials & Users — own-account login, in the container

**The dread this kills:** "how do Anthropic + GitHub creds get into this thing
without a heavy users/accounts/API-key system, and without violating anyone's
ToS." The answer: **the container is the credential boundary, and the driver
logs in with their own accounts via the official CLIs.** No provisioned API
keys, no shared creds, no DB.

## The core model

**The container is where credentials live.** A workspace's container holds the
driver's own logins — `~/.claude` (Claude), `~/.config/gh` (GitHub), `~/.gitconfig`
(name/email). The ACP harness runs *in that container* and reads `~/.claude`
directly; in-container `git`/`gh` use the GitHub login + identity. Nothing has to
"cross" from host to container, because the user authenticated *in* the
container in the first place. (This is the correction to the earlier
"sub-login can't reach a Linux container" blocker — it only couldn't because we
were logging in on the host.)

**One driver per session (the screen-sharing model).** Multiplayer is *"I'm
driving, you're working with me"* — not credential-sharing. An agent/workspace is
**owned by the user who spawned it**, and runs entirely on *that* user's logins:
their Claude sub for inference, their GitHub for clone/push, their name/email on
commits. Guests watch and contribute through the multiplayer UI, but they do not
inject their own creds into the driver's session. So there is never a "whose
key / merge keys" problem — a session has exactly one credential owner.

**Own-account OAuth, not provisioned keys (the ToS reason).** The user
authenticates with *their own* Claude and GitHub accounts through the official
CLIs (`claude` login, `gh auth login` — both OAuth/device flows). They are the
customer; Loopyard is just the box. We do **not** hand out or hold API keys as
the primary path — that drags users into the developer/commercial relationship
and smells like reselling inference. API key stays available only as a fallback
for people who genuinely have an API account.

> ⚠ **ToS gate (verify before the multi-user/product step):** using *your own*
> Claude sub in *your own* container for *your own* coding is clearly fine (it's
> what devcontainers/Codespaces do). A multi-tenant server orchestrating *many*
> users' subs headless is grayer. The direction (own account vs provisioned
> keys) is unambiguously more end-user-friendly, but confirm the multi-tenant
> headless case against Anthropic's terms before building the product on it.
> GitHub device-flow login for an own account is well within bounds.

## What a "user" is

A **lightweight profile, not an account.** No passwords, no login system, no DB.
`{id, name, email, created_at}` in `~/.loopyard/users.json` (+ ETS), exactly like
`canonical_projects.json` / `ports.json`. The existing BasicAuth plug + LAN trust
is the *access* gate; a user is just *"who am I acting as / driving as."*

- **First run:** pre-fill name/email from the host's `git config --global
  user.name/user.email` — zero typing for the common case.
- **MVP = just your profile.** One user (you) unblocks everything below.
  Multi-user (profile switcher, per-session binding, guest connect) is a strictly
  *additive* later layer — a Settings page first, an identity system never.

Because the providers' own cred stores (in the persisted per-user home, below)
hold the tokens, there is **no heavy encrypted API-key vault** to build. Loopyard
mostly orchestrates *the login* and *its persistence*.

## The three credentials and how each flows

| The driver has… | Lives in | Used by | Unblocks |
|---|---|---|---|
| **name + email** | `~/.gitconfig` (from profile) | `git` commits in the container (replaces today's hardcoded `Loopyard <loopyard@local>`) | real git authorship |
| **GitHub login** | `~/.config/gh` (`gh auth`) | in-container git + control-plane clone/push, acting *as the user* | "pull in repos", push, integrate |
| **Claude login** | `~/.claude` | the in-container ACP harness | per-user inference **+ ACP** |

## Where creds live + persistence

The work-container image already ships `git`, `gh`, and `@zed-industries/claude-code-acp`
(`priv/workspace-base/Dockerfile`), so the tools are present to log in.

Container filesystems are ephemeral (a rebuild wipes `~/.claude` / `~/.config/gh`).
So: **a per-user "home" Docker volume** (e.g. `loopyard-user-<id>-home`) mounted at
the relevant home paths in *every* container that user drives. Log in once → all
your workspaces have it; survives rebuilds.

- Per-**user**, not per-workspace: your Claude login is yours across all your
  workspaces.
- It's a Docker volume, **not** the code volume → never git-committed, never
  synced to GitHub.
- At-rest: on a local server this matches the bar of `~/.claude` on your laptop
  (host disk under the admin's control). For a hosted product, add disk
  encryption — note it, don't build it now.

## The login UX (not terminal-fishing)

The official CLIs use **device flows**, so Loopyard surfaces the login in the UI
instead of making people fish in a shell:

1. **"Connect GitHub" / "Connect Claude"** button → runs the official CLI's login
   *in the driver's container* → shows the `…/login/device` code + link right in
   the chat (multiplayer: the code shows for the room; the server polls).
2. On success the creds land in the per-user home volume → the harness + git just
   work.
3. The raw **container terminal still exists** for people who'd rather
   `claude login` / `gh auth login` themselves — and for their own tools/dotfiles.

## Control-plane git acts *as the user*

The one gap in "creds live in the container": some git ops run server-side in
transient `alpine/git` containers (`CanonicalRepo` clone-at-create, integrate
push). To act as the driver rather than `loopyard@local`:

- **Mount the owner's home volume** into those transient git containers (so
  `~/.config/gh` + `~/.gitconfig` are present), **or** run those ops in the
  owner's work container.
- Then clone/push authenticate as the user (via `gh`'s git credential helper),
  and merge commits carry their authorship.

## Build order (layered, de-dreaded)

1. **Admin / single-user, host-sourced (smallest, unblocks *you* today).**
   - Server reads the host's `git config user.name/email`, `gh auth token` /
     `GH_TOKEN`, and `ANTHROPIC_API_KEY` (if set) and injects them: identity →
     in-container `git config`; GitHub token → control-plane git; Anthropic →
     harness env (`-e` into the ACP `docker exec`; inherited by host-side
     `claude -p`). No UI. Gets you ACP + GitHub pull/push immediately, using
     *your* host logins.
   - Replace the hardcoded `loopyard@local` in `Tools.Container.Git`.

2. **Profiles + per-user home volume + in-UI device-flow "Connect" buttons (the
   product / screen-share-with-guests layer).**
   - `User` profiles (`users.json`); session→user binding via the cookie.
   - Per-user home volume; mount into the user's containers (work + transient
     git) — log in once, persists.
   - "Connect GitHub" / "Connect Claude" surfaced in the UI (device flow run in
     the container).
   - Agent records its owning `user_id`; harness/git run on the owner's home.
   - **(ToS gate here.)**

3. **Polish:** API-key fallback for API-account users; co-authorship trailers
   for guest contributions; disk encryption for a hosted deployment.

## Code touch-points (for whoever implements)

- `Tools.Container.Git` (`run_git_in_container`) — currently hardcodes
  `git config user.email 'loopyard@local'` / `user.name 'Loopyard'`. Source from
  the driver's profile / `~/.gitconfig`.
- `WorkContainer.ensure_up/1` + the ACP `docker exec` spawn — mount the owner's
  home volume; pass `ANTHROPIC_API_KEY` only as the fallback path.
- `CanonicalRepo` (`init_from_remote` / `push` / `integrate`) — mount the
  owner's home volume into the transient git container so clone/push act as the
  user (replaces token-in-URL injection for the own-account path).
- `Onboarding` — `users.json` load/restore alongside `canonical_projects.json`;
  pre-fill from host `git config` on first run.
- New: `Loopyard.Users` (profiles), the per-user home volume lifecycle, the
  device-flow "Connect" LiveView surface.

## Non-goals / decided

- **No provisioned/held API keys as the primary path** — own-account login only.
- **No credential sharing or merging across users** — one driver per session;
  multiplayer is screen-share, not key-pooling.
- **No accounts/passwords/DB** — profiles in JSON, providers' own cred stores in
  a per-user Docker volume.
- **GitHub is never a hard requirement** — scratch/local projects need none of
  this; Anthropic has the host/admin fallback.
