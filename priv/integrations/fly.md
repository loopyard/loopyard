# Fly

Deploy to Fly.io from the box. Fly reads a token from the env, so this one's an
**env var** (`FLY_ACCESS_TOKEN`) — needs a Restart to apply.

## Mint a token on your Mac

```
fly auth token | curl -fsS -T - $LOOPYARD/workstations/$WS/env/FLY_ACCESS_TOKEN
```

(Not logged in on your Mac? `fly auth login` first. Or mint a scoped token with
`fly tokens create deploy`.)

Then hit **Restart** on the workstation so the env var takes effect.

## Check it
After Restart: `fly auth whoami` in the console.
