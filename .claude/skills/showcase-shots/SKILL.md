---
name: showcase-shots
description: Generate marketing/product screenshots of real Loopyard views with mock data — SwiftUI-previews-style scenes shot at mobile + desktop viewports, no server needed. Use when making marketing images, feature-page screenshots, or visually checking a component state.
---

# Showcase shots — product screenshots without a server

Loopyard has a SwiftUI-previews-style rig: **scenes** pair a real view
component with canned mock assigns, and `mix loopyard.shot` renders them
statically (no Phoenix server, no Docker, no agents) and screenshots them
with headless Chrome.

## Take screenshots

```bash
mix loopyard.shot                     # every scene × {mobile, desktop}, light
mix loopyard.shot chat-working        # one scene
mix loopyard.shot --viewport mobile   # one viewport
mix loopyard.shot --theme dark        # dark variants (adds -dark suffix)
mix loopyard.shot --out ../website/priv/content/marketing/features/shots
mix loopyard.shot --list              # list scenes
```

Output: `tmp/showcase/<scene>-<viewport>[-dark].png`, 2× retina.
Viewports: mobile 390×844, desktop 1440×900.

## Add a scene

1. Create `lib/loopyard_web/showcase/scenes/<name>.ex`:

```elixir
defmodule LoopyardWeb.Showcase.Scenes.MyScene do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "my-scene",
    description: "One line about what it shows"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &SomeModule.some_component/1

  @impl true
  def assigns, do: %{...}   # ALL state — no ETS, no globals
end
```

2. Register the module in `LoopyardWeb.Showcase.@scenes`.
3. `mix loopyard.shot my-scene` and Read the PNG to verify.

Mock factories live in `LoopyardWeb.Showcase.Mock` (agent maps, message
maps in the exact runtime shapes, the shared "storefront" demo narrative).
Timestamps are fixed OFFSETS from render time, so relative labels ("4m
ago", Working) read live while the transcript's chronology never changes.

## The scenes are feature-view contracts (CI)

`test/loopyard_web/showcase_test.exs` renders every scene (light + dark)
on every CI run and asserts its load-bearing content markers. The scene
module's `description/0` + the marker list in that test are THE spec for
what each surface shows — when you deliberately change a view, update
both together. A new scene without a marker contract fails the suite.
Screenshots themselves are generated on demand (not in CI — Chrome), but
green tests mean the shot pipeline still renders.

Website pages consume the shots as light/dark pairs: every scene is shot
in both themes (`--theme dark` adds a `-dark` suffix) and the site swaps
via `<picture>` + `prefers-color-scheme`. Always regenerate BOTH themes
when reshooting.

## Rules and gotchas

- **Scenes only work on pure components.** If a view can't be a scene, it's
  reading ETS/GenServers inside render — extract the render into a component
  that takes assigns (LiveView loads state; component draws it). That's the
  decoupling this rig exists to enforce.
- **Hook-owned regions render empty** (`phx-update="ignore"` + client
  appends). Give the component an optional server-seeded assign gated on
  `assigns[:static?]` — see `streaming_thinking`'s `initial` — and set
  `static?: true` in the scene. Never seed it live: the first delta both
  creates the element and pushes its text, so a live seed doubles chunk one.
- **Theme is pinned deterministically** (headless Chrome inherits OS dark
  mode) by rewriting the `prefers-color-scheme` media query in the inlined
  CSS. Light is default; `--theme dark` for dark.
- **Chrome clamps windows to ~500px wide.** Narrow viewports render framed
  at true width inside a 500px window and get center-cropped (sips/magick).
  Don't "fix" a mobile shot by widening the viewport.
- Transcripts auto-scroll to the tail (the page injects a scroll snippet),
  matching the live app's bottom-anchor.
- CSS comes from `priv/static/assets/app.css` — run `mix tailwind loopyard`
  first if you changed styles.

## Marketing pipeline

Feature pages live in the website repo
(`~/Projects/loopyard/website/priv/content/marketing/features/`). Shoot with
`--out` into a shots directory there, reference the PNGs from the page
markdown. Site copy rules apply to the pages (no em dashes in
`priv/content/`), not to screenshots.
