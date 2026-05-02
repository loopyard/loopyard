# Git hygiene

Two rules. That's it.

## 1. Atomic commits

**One commit, one logical change, cleanly revertable.**

A commit is atomic if you can describe it in one sentence without using
"and." When something breaks in production, `git revert <sha>` has to
undo the broken change without also reverting unrelated work that
shipped alongside it. A commit that bundles a feature with a drive-by
refactor can't be reverted cleanly — you get the bug back *and* you
lose the refactor.

| Atomic | Not atomic |
|--------|------------|
| `stream exec output to chat in real-time` | `exec streaming and scroll fix and port cleanup` |
| `fix agent restore: use Persistence.log_path everywhere` | `agent restore + thinking indicator + tool summary` |
| `add thinking indicator contract tests` | `tests and refactoring and new feature` |

**Tests ship in the same commit as the code they test** — they are
part of the same logical change, not a separate commit.

**Drive-by fixes get their own commit.** If you spot a typo while
implementing a feature, that's a separate commit, not a hitchhiker.

When the working tree has unrelated changes, use `git add -p` to stage
hunk-by-hunk until the index matches exactly one logical change.
Commit. Repeat.

## 2. Sane commit messages

**A subject line a human would understand on its own, plus a body when
the *why* isn't obvious from the diff.**

A good message tells a future engineer (or future you) why this change
exists. The diff already shows what changed; the message carries the
context the diff can't.

```
short, specific subject — present tense, under ~70 chars

Optional body explaining *why* this change exists. Skip the body
when the diff is self-explanatory; write one when it isn't.
```

Examples of sane subjects from this repo's history:

- `fix agent restore: use Persistence.log_path everywhere`
- `block git checkout/switch in workspaces — one branch per workspace`
- `use flex-col-reverse for chat scroll — browser-native bottom anchor`

If you like Conventional Commits prefixes (`feat:`, `fix:`, `chore:`,
`docs:`, `refactor:`), use them — they make `git log` skim-able. They
aren't required, just useful. The actual rule is *clarity*, not format.

## Things to actually be careful about

These can break shared state or lose work:

- **Don't `git push --force` to `main`.** Rewriting shared history
  diverges from anyone who pulled. Force-push to a feature branch
  before merge is fine.
- **Don't amend a commit you've already pushed.** Make a new commit
  (a `fix:` or a `git revert`) that corrects the previous one.
- **Don't skip hooks** (`--no-verify`, `--no-gpg-sign`) without a
  specific reason and explicit ask. If a hook fails, fix the cause.
- **Always work on a feature branch** unless the change is trivial.
  One branch per feature/fix — don't pile unrelated work onto a branch.

Everything else (commit format, scope naming, body wrapping, push
cadence) — use judgment.
