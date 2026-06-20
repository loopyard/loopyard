# GitHub

Give the workstation (and every agent) your GitHub access — clone private repos,
push branches, open PRs with `gh`.

## Connect from your phone (`gh auth login`)

The path that needs **no laptop and no fixed URL**. `gh auth login` is GitHub's
OAuth **device flow**: GitHub hosts the verification page, so nothing has to call
back to this box.

1. Tap **▶ gh auth login …** under *Use the terminal* below. It runs in the box
   and prints a **one-time code** and the URL **github.com/login/device**.
2. Open **github.com/login/device** **on your phone**, sign in, and enter the
   code.
3. Approve the access. The box's `gh auth login` is polling — once you approve it
   completes on its own (nothing to paste back).

That's it — a full connect with nothing but the phone in your hand. The flags on
the command pre-answer gh's prompts (github.com → HTTPS → web → skip SSH key) so
you go straight to the code.

The login lands in the box's **persistent `$HOME` volume** (`~/.config/gh`), so it
**survives a Restart** — no token to copy into any box. And because `--git-protocol
https` configures gh as git's credential helper, `git clone`/`push` over HTTPS just
work too.

## Quick start: transfer your Mac login

The **"Run this on your Mac"** command above does it from the machine where you're
already logged in: it reads your `gh` token (from the macOS Keychain via `gh auth
token`) and pushes **both** a live `~/.config/gh/hosts.yml` (so `gh` works
immediately) **and** the `GITHUB_TOKEN` env var (for tools that read it, on the
next Restart).

> On macOS `gh` keeps its token in the Keychain, so there's no `~/.config/gh/hosts.yml`
> file to copy — the command rebuilds one from `gh auth token`. A plain file copy
> only works if you logged in with `gh auth login` on a Linux host.

## A token

Paste a `gh auth token` value (or a fine-grained PAT) into the `GITHUB_TOKEN` slot
under *Set a token*. `gh` honors `GH_TOKEN`/`GITHUB_TOKEN`. Needs a Restart.

## Check it

`gh auth status` in the console — "Logged in to github.com" means you're connected.
The card shows **Connected** once that's true.
