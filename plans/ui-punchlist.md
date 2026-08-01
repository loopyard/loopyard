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

## NOT DONE — still outstanding

**A. Option tap has latency (the big one).** Tapping an answer flickers and
does nothing for seconds. Selection is a SERVER round-trip
(`draft_question_option` → broker → broadcast → re-render), so while an agent
streams, the re-render lands seconds later and unchecks the click. Fix: real
`<input type="radio">` so the BROWSER owns selection (instant), with the push
only for durability/multiplayer. Note: the options are `<button type="button">`
today, which is why the `group-has-[:checked]` rule I added is dead CSS — it
can never match. That wants removing with the same change.

**B. Desktop question layout.** Asked for: Answer half-width on the LEFT
directly under the options, ghosts off to the right. Currently the reverse
(ghosts left, Answer right).

**C. Changes / History show the Files status.** All three route to
`detail_kind == :volume`, so the same volume panel renders for each. Should
summarise: recent changes for Changes, most-recent commit for History.

**D. Integration pages are a mess** (`/workstations/:id/claude`, and the
pattern for GitHub / Fly). Wanted: STATUS most dominant, then how to hook it
up; "Other ways" as links to sub-pages; drop the stray Reference/docs block at
the bottom. Establish one pattern all integrations follow.

**E. Stuck agent after re-auth.** An agent wedged mid-turn ("Brewing… 23m")
doesn't reset when a new credential lands. Suspected deadlock:
`reload_agents` → `restart_session(:credentials)` vs. the
never-kill-a-busy-harness rule — but "busy" is a lie when the turn died on
auth. Needs: detect a turn that can't progress and let a credential push
force the reset.

**F. Operator rail** — flagged as "a typographical nightmare with bad mobile
touch targets and an inconsistent sidebar look". Untouched. Should compose
`ProjectList.project_groups` rather than its own `PAST HOUR` / `TODAY` rows.

**G. Reviewer scroll/snap.** Replace prev/next arrows with a scroll-snap deck
(`scroll-snap-type: y proximity`, `scroll-snap-align: start` — proximity so a
question taller than the viewport doesn't fight the user). It's a state
restructure: ReviewLive renders one slide with subscriptions keyed to it.
