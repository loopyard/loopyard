# UI punch list — everything Brad flagged this session

Written down because I was working reactively and dropping items. Each line
is verified by screenshot or measurement, or it's marked NOT DONE. No item
gets ticked on the strength of "I edited a file".

## Done + verified

| # | Ask | Verified by |
|---|-----|-------------|
| 1 | Homepage keeps the top bar so chrome doesn't shift | 7 routes × 2 viewports all `h:56, top:0` |
| 2 | Focused views get the top-left anchor | `loopyard › Operator` renders on `/review` |
| 3 | Breadcrumb model: brand left, ancestors chevroned, current centred | `Breadcrumbs.trail/1` + `current/1`; all 3 headers compose them |
| 4 | No trailing chevron after the last ancestor | `loopyard › Hello-World`, nothing dangling |
| 5 | Mobile breadcrumb = back button only, no logo/dividers | `mobile: :back` on Breadcrumbs |
| 6 | Chat view gets the same bar as every surface | measured 56px, matches |
| 7 | Centre shows the project·workspace PAIR | `Hello-World · master` |
| 8 | Use `workspace_identity` everywhere (top bar, switcher) | both render the component |
| 9 | Drop the redundant "Ready" from the title bar | `grep -c status_label` → 0 |
| 10 | Switcher header centres the same thing, no shift | chevron 274px → 276px |
| 11 | Rails: 44px tap targets, shared gutter, 8× rhythm | headings 24→44px; dots and headings both x=8 |
| 12 | Left rail + dashboard at the sidebar type scale | both rails 15px; dashboard rows 15px |
| 13 | Dashboard card titles a bump bigger | 16 → 18px |
| 14 | Timestamps hard right on prompt / queue / turn header | right edge 374 of 390 |
| 15 | Queue label just "Queued", band desaturated a notch | violet-50 / #241f3a |
| 16 | Short chats start at the TOP (was `mt-auto`) | short chat y=172 (was 717); long chat still lands at end |
| 17 | Question actions: mobile stacked, desktop row | Answer 52px on top; desktop Answer right |
| 18 | Answer dominant; Skip furthest + quietest | Answer 678, Chat 698, Skip 746 |
| 19 | Three actions in one place (Skip / Chat / Answer) | `chat_path` attr on `question_block` |
| 20 | Sign-in expired LINKS to the fix | test asserts href → `/workstations/:id/claude` |
| 21 | Agent panel collapses, closed by default, CSS slide | `grid-template-rows: 0fr→1fr` |
| 22 | Panel actions pinned outside the fold, side by side | Restart x=1133, Remove x=1284, same y |
| 23 | Remove confirm states the consequence | contains "cannot be undone" |
| 24 | Service actions on one row | `grid-cols-3` |
| 25 | Duplicate Stop removed from the turn header | 1 Stop on screen |

## Done + verified (second pass)

| # | Ask | Verified by |
|---|-----|-------------|
| 26 | Dashboard card titles a bump bigger | 16 → 18px, all three |
| 27 | Rail questions bigger, orange `?` icons gone | rows 13 → 15px, 0 icons, text runs 70+ chars instead of truncating at 35 |
| 28 | Operator summary says something | gauge names nouns ("4 questions · 2 approvals"); the asks themselves are listed and tappable |
| 29 | "Claude — finished a turn" ×5 killed | digest stores the agent's closing sentence; test forbids the placeholder string |
| 30 | Status out of the top-right corner | all three cards: clickable gauge line under the title |
| 31 | Option tap is instant | real `<input>`; 0.9ms in-frame, survives unrelated re-renders |
| 32 | Answer half-width LEFT, ghosts right | Answer x=410 w=311; Skip 903, Chat 969 |
| 33 | Type scale unified | 72 ad-hoc `text-[10/11/13px]` → one `.section-label` + the 14px floor; nothing renders below the scale |
| 34 | Duplicate page titles gone | /workspaces H1 dropped; /review anchors subject left, centres "Review 1 of 6" |
| 35 | "Ready" beside a green dot gone | `notable_state?/1` — only a state that departs from rest gets words |
| 36 | Disk at 19% stops alarming | was `String.contains?(pct, "9")`; now a number ≥ 90 |
| 37 | Mobile 44px targets | `/` and `/workspaces` clean; Back, list rows, project header fixed |
| 38 | Dead `/remote/` link removed | route was deleted with the binding flag; link 404'd |
| 39 | `workspace_live.ex` back under its size cap | 1906 → 1888; tree patch moved to `WorkspaceTree` |

Full suite green: 1818 passed, 121 excluded.

## NOT DONE — still outstanding

**C. Changes / History show the Files status.** All three route to
`detail_kind == :volume`, so the same volume panel renders for each. Should
summarise: recent changes for Changes, most-recent commit for History.

**D. Integration pages are a mess** (`/workstations/:id/claude`, and the
pattern for GitHub / Fly). Wanted: STATUS most dominant, then how to hook it
up; "Other ways" as links to sub-pages; drop the stray Reference/docs block at
the bottom. Establish one pattern all integrations follow.

**E. Stuck agent after re-auth.** An agent wedged mid-turn ("Brewing… 23m")
doesn't reset when a new credential lands. Suspected: `reload_agents` →
`restart_session(:credentials)` vs. the never-kill-a-busy-harness rule — but
"busy" is a lie when the turn died on auth. Needs a way to tell a turn that
can't progress from one that's working.

**F. Operator rail** — rows now read at the sidebar scale with no icons, but 14
elements still sit under 44px on mobile and it composes its own `PAST HOUR` /
`TODAY` rows instead of `ProjectList.project_groups`.

**G. Reviewer scroll/snap.** Replace prev/next arrows with a scroll-snap deck
(`scroll-snap-type: y proximity`, `scroll-snap-align: start` — proximity so a
question taller than the viewport doesn't fight the user). It's a state
restructure: NotificationsLive renders one slide with subscriptions keyed to it.

**Deliberate exception:** the question card's Skip/Chat stay at 40px, under the
44px floor. They're sized down relative to Answer so discarding a question
isn't a plausible mis-tap; expanding their hit area would undo that.
