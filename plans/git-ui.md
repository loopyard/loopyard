# Git UI: staged files, commit detail, mobile-friendly diff viewer

## Current state

The git tab (`/volumes/:name/git`) shows:
- Working tree changes (clickable → inline diff pane)
- Recent commits (clickable → inline diff pane)
- Diff viewer as a `max-h-[60vh]` `<pre>` block at the bottom

### Problems

1. **No staged vs unstaged distinction.** `git_status` shows all changes
   but doesn't indicate which are staged. You can't tell what will be in
   the next commit.

2. **Diff pane sticks below the viewport.** On screens that aren't tall
   enough, the diff renders below the fold. You click a file, nothing
   visually changes — you have to scroll down. On mobile it's unusable.

3. **Commits are unexpandable.** You see the commit message and short SHA
   but can't see what files changed or the diff for a specific commit.

4. **No mobile layout.** The diff pane should be a full-screen view on
   mobile (like the file browser does with its own route), not an inline
   panel.

## Design

### Staged vs unstaged

Show two sections:

```
Staged (ready to commit)
  A  app/models/user.rb
  M  config/routes.rb

Unstaged changes
  M  app/views/users/show.html.erb
  ??  tmp/debug.log
```

The Source.Local git tools already have `git_status` which returns
`git status --porcelain`. Parse the two-column status format:
- Column 1 = index (staged) status
- Column 2 = worktree (unstaged) status
- `M_` = staged modification, `_M` = unstaged modification
- `A_` = staged new file, `??` = untracked

### Routes instead of inline panes

Replace inline diff pane with proper routes:

```
/volumes/:name/git                           → overview (staged, unstaged, recent commits)
/volumes/:name/git/diff/:path                → diff for a specific file (staged or unstaged)
/volumes/:name/git/commits/:sha              → commit detail (files changed + diff)
/volumes/:name/git/commits/:sha/diff/:path   → diff for one file in a commit
```

Each is a full page. Mobile gets the whole screen. Desktop shows it in
the main content area (same as file browser). Back button works.

### Commit detail page

Click a commit → see:

```
commit abc1234
Author: Agent "Setup" <agent@loopyard>
Date: 2 minutes ago

  Add user authentication with Devise

  Files changed (3):
    M  app/models/user.rb          +15 -3
    A  app/controllers/sessions.rb  +45
    M  config/routes.rb             +5 -1

  [click any file to see its diff]
```

### Diff viewer

Proper side-by-side or unified diff with:
- Syntax-highlighted added/removed lines (green/red, using the existing
  `colorize_diff` but cleaned up)
- File header showing the path
- Line numbers (unselectable, same pattern as text_viewer)
- Collapsible hunks for large diffs

Use Makeup's diff lexer (`makeup_diff`) for syntax highlighting if
it works well enough, otherwise keep the manual colorization.

### Mobile layout

The same pattern the file browser uses:
- Route-based navigation (each view has its own URL)
- Full-screen on mobile (hidden sidebar)
- Breadcrumb back navigation
- Swipe-friendly (no horizontal scroll for narrow diffs — wrap lines)

### Implementation

1. **Parse staged vs unstaged from git status** — update `Source.Local.git_status`
   to return `%{path, index_status, worktree_status}` instead of just `%{path, status}`
2. **Add routes** — `/git/diff/:path`, `/git/commits/:sha`, `/git/commits/:sha/diff/:path`
3. **Commit detail component** — shows files changed with add/remove counts
4. **Diff viewer component** — full-page, syntax-highlighted, line numbers
5. **Remove inline diff pane** — replace with `push_patch` to the diff route
6. **Mobile CSS** — same responsive pattern as file browser

### Connection to Source adapters

The git data comes from `Source.Local` which shells out to the host's git
on the worktree. Future adapters (GitHub) would get commit/diff data from
the GitHub API instead. The UI components are adapter-agnostic — they
receive structured data (commits, status, diffs) and render it.
