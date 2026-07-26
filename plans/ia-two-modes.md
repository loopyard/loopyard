# IA reset: two modes, not a tree

## The insight (Brad, Jul 26)

The app is used in exactly two postures:

1. **Workspaces** — *in the work*: a project's workspace, its agents, files,
   services. Deep focus.
2. **Operator** — *running the shop*: the chief of staff, the fleet, what needs
   you. Includes the **workstations** (the operator's own containers/credentials)
   — they're the operator's body, not a separate concern.

Everything else — `/system/*` observability, `/remote` (Connect), ports,
secrets, docker — is **System**: plumbing you click off to on purpose, then
leave. Not a mode; a destination.

So the top-level IA stops being a tree (Root → Projects → Workspaces →
Agents…) and becomes a **mode flip**:

```
┌──────────────────────────────────────────────┐
│  [ Workspaces ]  ⇄  [ Operator ]      ⚙ System │
└──────────────────────────────────────────────┘
```

- The flip is the ONE persistent global control (top-left, where the wordmark
  breadcrumb lives today). Each mode remembers where you were in it — flipping
  back returns you to your last workspace / the operator chat.
- **System** is a quiet gear, not a peer mode. It gathers: /system/* (health,
  events, sagas, quarantine, orphans, recovery, reconcilers, workspaces,
  docker, ports, secrets) + /remote (Connect). One landing page, sections.

## Iconography

The three destinations get fixed icons, used everywhere they're named:

- **Workspaces** — the 2×2 squares grid (places of work).
- **Operator** — the trefoil mark itself (`Brand.mark`): the operator is
  loopyard's mind; the brand mark is its face.
- **System** — the gear. Conventional on purpose.

## What moves where

| Today | Becomes |
|---|---|
| `/` root dashboard | Workspaces mode home (or straight to last workspace) |
| `/workspaces`, `/projects/...` | Workspaces mode (unchanged internally) |
| `/operator`, `/queue` | Operator mode |
| `/workstations*` | Operator mode (a section of the operator surface) |
| `/system/*` | System (unchanged routes, one nav home) |
| `/remote` (Connect) | System |
| `/sound`, `/aural` | System (ambient config) — the sound *player* stays docked in Operator |

## Phasing (routes never break — nav changes first)

1. **Mode shell** — the global header/sidebar chrome gets the Workspaces ⇄
   Operator flip + the System gear. Breadcrumbs demote to within-mode context.
   Last-location memory per mode (session-scoped assign or localStorage-free:
   server-side per-LiveView-session).
2. **Operator absorbs workstations** — /workstations renders inside the
   Operator mode chrome (link section in its rail); /queue folds into "For you".
3. **System home** — /system becomes the gathered landing (its current health
   map + links to every subpage + Connect/remote + sound settings).
4. **Cleanup** — old cross-links updated; the root `/` redirects into the
   Workspaces mode home.

Old URLs keep working throughout — this is chrome + grouping, not route churn.

## Native trajectory

The mode nav is deliberately shaped like an iOS tab bar: a future native
wrapper renders Workspaces / Operator / System as three glass tab buttons over
the same three roots — no IA change needed. Keep the modes URL-rooted
(`/workspaces`, `/operator`, `/system`) and self-contained so the wrapper can
treat each as a tab's root view; safe-area handling already exists (pb-safe /
safe-area-*).

## Non-goals

- No per-page redesigns beyond the chrome (bands/cards/type stay as shipped).
- No auth/roles.
- No merging of workspace internals (Agents/Services/Files) — that IA stays.
