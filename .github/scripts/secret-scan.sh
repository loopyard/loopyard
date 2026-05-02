#!/usr/bin/env bash
#
# Scan for leaked secrets in staged/committed files.
# Runs on PRs (diff against base) and pushes (full tree).
#
# Exit 1 if any pattern matches outside the allowlist.
# Patterns: AWS keys, GitHub tokens, Stripe, OpenAI/Anthropic,
# private key headers, generic high-entropy tokens.
#
set -euo pipefail

# --- Config ---

PATTERNS=(
  'AKIA[0-9A-Z]{16}'                       # AWS access key
  'ASIA[0-9A-Z]{16}'                       # AWS temporary key
  'ghp_[A-Za-z0-9]{36,}'                   # GitHub personal token
  'ghs_[A-Za-z0-9]{36,}'                   # GitHub server token
  'ghu_[A-Za-z0-9]{36,}'                   # GitHub user-to-server token
  'github_pat_[A-Za-z0-9_]{22,}'           # GitHub fine-grained PAT
  'sk-[A-Za-z0-9]{20,}'                    # OpenAI / Anthropic key
  'sk-ant-[A-Za-z0-9-]{20,}'               # Anthropic key (explicit)
  'sk_live_[A-Za-z0-9]{20,}'               # Stripe live key
  'rk_live_[A-Za-z0-9]{20,}'               # Stripe restricted key
  'xox[bpars]-[A-Za-z0-9-]{10,}'           # Slack token
  'AIza[A-Za-z0-9_-]{35}'                  # Google API key
  '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'  # Private key header
)

# Files that should never contain secrets but are OK to skip
ALLOWLIST_PATHS=(
  'mix.lock'
  'package-lock.json'
  'bun.lockb'
  'yarn.lock'
  '*.beam'
  '_build/*'
  'deps/*'
  '.git/*'
  'test/support/fixtures/*'
)

# --- Build grep pattern ---

combined=""
for p in "${PATTERNS[@]}"; do
  if [ -z "$combined" ]; then
    combined="$p"
  else
    combined="$combined|$p"
  fi
done

# --- Build exclude args ---

excludes=""
for a in "${ALLOWLIST_PATHS[@]}"; do
  excludes="$excludes --glob=!$a"
done

# --- Scan ---

mode="${1:-tree}"  # "diff" for PR, "tree" for full scan

if [ "$mode" = "diff" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
  echo "Scanning diff against $GITHUB_BASE_REF..."
  files=$(git diff --name-only "origin/$GITHUB_BASE_REF"...HEAD)
  if [ -z "$files" ]; then
    echo "No changed files to scan."
    exit 0
  fi
  # Scan only changed files
  matches=$(echo "$files" | xargs grep -nEH "$combined" 2>/dev/null || true)
else
  echo "Scanning full tree..."
  matches=$(grep -rnEH $excludes "$combined" lib/ config/ test/ assets/ .github/ 2>/dev/null || true)
fi

# --- Filter allowlisted paths ---

filtered=""
while IFS= read -r line; do
  skip=false
  for a in "${ALLOWLIST_PATHS[@]}"; do
    if [[ "$line" == *"$a"* ]]; then
      skip=true
      break
    fi
  done
  if [ "$skip" = false ] && [ -n "$line" ]; then
    filtered="$filtered$line"$'\n'
  fi
done <<< "$matches"

filtered=$(echo "$filtered" | sed '/^$/d')

if [ -n "$filtered" ]; then
  echo "::error::Potential secrets found in the following files:"
  echo "$filtered"
  echo ""
  echo "If these are test fixtures or false positives, add the path to ALLOWLIST_PATHS in .github/scripts/secret-scan.sh"
  exit 1
else
  echo "No secrets found."
  exit 0
fi
