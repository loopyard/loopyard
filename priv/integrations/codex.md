# Codex

OpenAI Codex CLI. Its login lives in a **file** (`~/.codex/auth.json`), not an
env var — so the easy path is to copy that file up. Lands in `~/.codex/auth.json`
in the shared `$HOME` volume: **live**, every agent inherits it, no Restart.

## Already logged in on your Mac (recommended)

```
curl -fsS -T - $LOOPYARD/workstations/$WS/file/.codex/auth.json < ~/.codex/auth.json
```

(If you're not logged in there yet: `codex login` on your Mac first.)

## Or use an API key

`codex` also honors `OPENAI_API_KEY`. Paste it into the env slot on the index if
you'd rather use a key than your ChatGPT login.

## Check it
`test -f ~/.codex/auth.json` in the console — present means it's there.
