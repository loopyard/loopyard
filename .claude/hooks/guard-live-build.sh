#!/usr/bin/env bash
# Deny `mix compile|test|format` against the LIVE checkout while the dev server
# is running.
#
# Why: the server runs from this checkout and holds the _build lock. A mix
# command here fights it for the lock and the server loses — it takes a SIGTERM
# and Brad's session dies mid-work. This happened three times in one night, each
# time after saying "I'll use the worktree."
#
# The fix isn't discipline, it's this hook: build in the worktree with its own
# MIX_BUILD_PATH, and only touch this checkout for the cutover (git merge).
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only mix commands that compile or lock the build dir.
case "$cmd" in
  *"mix compile"*|*"mix test"*|*"mix format"*|*"mix loopyard.shot"*) ;;
  *) exit 0 ;;
esac

# Already scoped to its own build dir → cannot collide. Allow.
case "$cmd" in *MIX_BUILD_PATH=*) exit 0 ;; esac

# Explicitly targeting the worktree → allow.
case "$cmd" in *loopyard-reliability*) exit 0 ;; esac

# Only guard while a server is actually listening.
if ! lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1; then exit 0; fi

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The dev server is running from this checkout and holds the _build lock — this command would fight it for the lock and kill the server (it has happened 3x). Build in the worktree instead:\n\n  cd ../loopyard-reliability && MIX_BUILD_PATH=_build_wt mix <cmd>\n\nUse this checkout only for the cutover (git merge --ff-only). To verify live state without building, use: mix loopyard.rpc '<expr>' (read-only, no lock)."}}
JSON
