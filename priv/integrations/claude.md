# Claude

Run Claude Code in the box on your Claude subscription (Pro/Max/Team) — no API key.

## Sign in (the button at the top of this page)

**Sign in to Claude** runs Claude's own headless login for you and walks it in
three steps, from any device:

1. Tap **Sign in to Claude**. Loopyard starts `claude setup-token` in a throwaway
   container and shows you its sign-in link.
2. Open the link, approve. Claude signs in **whichever account that browser is
   using** — to add a second account, switch accounts there first.
3. Paste the code Claude shows you. Loopyard hands it to the CLI, stores the
   one-year token as `CLAUDE_CODE_OAUTH_TOKEN` on this workstation, and the
   agents on this account reload themselves.

The token never reaches your browser, and there is no terminal to drive.

**More than one Claude account:** a workstation holds one. Create a workstation
per account ([Workstations]($LOOPYARD/workstations)), sign each in here, then
choose the account per agent in the chat sidebar's **Account** menu.

## By hand, from the terminal (`claude setup-token`)

The same flow the button drives, for when you want to watch it:

1. Tap **▶ claude setup-token** under *Use the terminal* below. It runs in the box
   and prints an **authorization URL**.
2. Open that URL **on your phone**, sign in, approve.
3. The browser shows a **code** (the box can't catch the local callback — expected
   in a container). Paste it back into the terminal at the `Paste code here`
   prompt.
4. `setup-token` prints a **token** (good for one year). Copy it into the
   **`CLAUDE_CODE_OAUTH_TOKEN`** box under *Set a token*, and **Restart**.

That's it — a full re-auth with nothing but the phone in your hand.

`CLAUDE_CODE_OAUTH_TOKEN` is the env var Claude Code reads for non-interactive use;
it takes precedence over `~/.claude/.credentials.json` and needs **no** `~/.claude`
files at all. The interactive-login token (`.credentials.json`) is short-lived and
401s within hours — this avoids that treadmill.

> Don't run `claude -p --bare` in the box — bare mode ignores the token. Plain `claude -p "…"` is fine.

## Quick start (expires): transfer your Mac login

The bulk **"Run this on your Mac"** command copies your *current* Claude login
(from the macOS Keychain item `Claude Code-credentials`) into `~/.claude`, plus a
minimal `~/.claude.json` so interactive `claude` doesn't re-run its login flow.
Enough to make `claude -p` work *right now* — but that token is short-lived. Use
the phone-native long-lived token above for anything lasting.

## Check it

In the console: `claude -p "say ok"` (should reply). The card shows **Connected**
once `CLAUDE_CODE_OAUTH_TOKEN` is set.
