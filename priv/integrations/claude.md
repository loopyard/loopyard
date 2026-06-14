# Claude

Claude Code in the box. Two ways, depending on what you've got:

## Copy your Mac's login file (live, no Restart)

```
curl -fsS -T - $LOOPYARD/workstation/$WS/file/.claude/.credentials.json < ~/.claude/.credentials.json
```

This mirrors your existing `claude login`. It uses your Claude subscription. The
access token refreshes itself from the refresh token in that file.

## Or a long-lived token (durable, env)

On your Mac (needs a browser): `claude setup-token` → paste the token into the
`CLAUDE_CODE_OAUTH_TOKEN` env slot on the index. This is durable (no hourly
refresh) but needs a Restart to apply.

> Heads up: Claude's interactive `/login` uses a localhost-loopback OAuth that
> does NOT work from a remote browser — that's why we copy the file or use
> `setup-token` instead.

## Check it
`test -f ~/.claude/.credentials.json` in the console.
