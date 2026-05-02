# Git Discipline

Two rules. Everything else follows from these.

## 1. Atomic commits

One commit = one logical change. Tests ship in the same commit as the code they test. Drive-by fixes get their own commit.

A good commit can be reverted with `git revert` and the codebase still works. If reverting your commit would break something that wasn't in the diff, the commit is too big.

**Good:** "Stream exec output to chat in real-time" (one feature, one commit)
**Bad:** "Fix scroll + add copy button + update port logic" (three unrelated changes)

Use `git add -p` to stage hunks when a work session touched multiple concerns.

## 2. Sane commit messages

- **Subject:** present tense, ~70 chars, what changed and why
- **Body:** explain *why* (the diff shows *what*)
- No "WIP", "fix", "update" — say what was fixed or updated

**Good:**
```
Fix agent restore: use Persistence.log_path everywhere

Bug: agent logs were written to ~/.boomlooper/workspaces/<id>/ but
read from workspace.path (the project source dir). Different paths
= agents vanish on restart.
```

**Bad:**
```
fix bug
```

## Rules

- Never `git push --force` to main
- Never amend pushed commits — make a new commit to fix
- Never skip hooks (`--no-verify`) without an explicit reason
- Always work on a feature branch unless the change is trivial
- One branch per feature/fix — don't pile unrelated work onto a branch
