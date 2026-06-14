# GitHub

Gives the workstation (and every agent) your GitHub access — clone private repos,
push branches, open PRs via `gh`. Lands in `~/.config/gh` in the shared `$HOME`
volume, so it's **live** — no Restart, every agent inherits it.

## Set it up — `gh auth login` in the console

Click **▶ Run** below (or run it in the console yourself):

```
gh auth login
```

Then, in the terminal:
1. Pick **GitHub.com** → **HTTPS** → **Login with a web browser**
2. Copy the one-time code it prints
3. Open **github.com/login/device** (tap the link — it's clickable), paste the code, authorize

That's it — it's a device flow, so it works from your phone too. No PAT needed.

## Already logged in on your Mac? Push it instead

```
curl -fsS -T - $LOOPYARD/workstation/$WS/file/.config/gh/hosts.yml < ~/.config/gh/hosts.yml
```

Or set just a token: `gh auth token` → the `GITHUB_TOKEN` env var (the slot on the
index). `gh` honors `GH_TOKEN`/`GITHUB_TOKEN`, so a fine-grained PAT works too.

## Check it
`gh auth status` — "Logged in to github.com" means you're connected.
