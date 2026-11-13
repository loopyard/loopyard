# Codex

OpenAI Codex CLI. A ChatGPT-plan login is a **file** (`auth.json`), not an env
var. Loopyard stores it **with this workstation** (this account) and hands each
agent on it its own copy at `~/.loopyard/codex.$WS/auth.json` (`CODEX_HOME`), so
two agents in one box can run on two different ChatGPT plans.

## Sign in to Codex (recommended)

Use **Sign in with Codex** at the top of this page. Loopyard runs
`codex login --device-auth` in a throwaway container and shows you a link and a
one-time code. Open the link on any device, sign in to the ChatGPT account you
want this workstation to use, enter the code, approve. The page finishes by
itself (the code expires after 15 minutes) and agents on this account reload.

Signing in again replaces the credential everywhere on the next agent start.
Until then, the copy inside each box is the live one — Codex refreshes it in
place.

## Or use an API key

`codex` also honors `OPENAI_API_KEY` / `CODEX_API_KEY`. Paste it into the token
slot below if you'd rather bill an API key than a ChatGPT plan.

## Older paths

`codex login --device-auth` in the console (or pushing your Mac's
`~/.codex/auth.json`) writes `~/.codex` in the box's shared `$HOME`. Agents on
this workstation keep using it until you sign in above; agents on OTHER accounts
never see it.

```
curl -fsS -T - $LOOPYARD/workstations/$WS/file/.codex/auth.json < ~/.codex/auth.json
```
