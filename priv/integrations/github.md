# GitHub

Gives the workstation (and every agent) your GitHub access — clone private repos,
push branches, open PRs via `gh`. The **"Run this on your Mac"** command above
does it: it reads your `gh` token (from the macOS Keychain via `gh auth token`)
and pushes **both** a live `~/.config/gh/hosts.yml` (so `gh` works immediately —
no Restart) **and** the `GITHUB_TOKEN` env var (for tools that read it, on the
next Restart).

> On macOS `gh` keeps its token in the Keychain, so there's no `~/.config/gh/hosts.yml`
> file to copy — the command rebuilds one from `gh auth token`. A plain file copy
> only works if you logged in with `gh auth login` on a Linux host.

## Alternatives

- **`gh auth login` in the console** (under *Other ways*) — a device flow that
  works from your phone: pick GitHub.com → HTTPS → web browser, then open
  **github.com/login/device** and paste the one-time code. No PAT needed.
- **A token** — paste a `gh auth token` value (or a fine-grained PAT) into the
  `GITHUB_TOKEN` slot. `gh` honors `GH_TOKEN`/`GITHUB_TOKEN`. Needs a Restart.

## Check it

`gh auth status` in the console — "Logged in to github.com" means you're connected.
