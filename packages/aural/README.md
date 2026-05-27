# Aural

Cerebral ambient audio bed for Phoenix apps. One synth + ffmpeg
pipeline per channel broadcasts MP3 chunks via `Phoenix.PubSub` to
every HTTP listener subscribed to that channel — N listeners pay
the cost of 1 encoder and all hear the same byte at the same
moment. Chimes mix into the bed PCM server-side for true harmonic
integration, with a 300 ms tail fadeout so they decay cleanly.

## Quickstart

```elixir
# mix.exs
{:aural,
 git: "https://github.com/loopyard/loopyard.git",
 sparse: "packages/aural",
 branch: "main"}
# or, for a sibling monorepo checkout:
# {:aural, path: "../loopyard/packages/aural"}
```

```elixir
# config/config.exs — Aural broadcasts on the host's PubSub
config :aural, pubsub: MyApp.PubSub
```

That's it for supervision. The package starts its own
`DynamicSupervisor` + `Registry`; channels lazy-spawn on first
call to any public function. Hosts add nothing to their supervision
tree.

```elixir
# lib/my_app_web/router.ex
import Aural.Router

pipeline :aural do
  plug :accepts, ["*/*", "json", "html", "mpeg"]
end

scope "/aural" do
  pipe_through :aural
  aural_routes()  # GET /, GET /:id/stream.mp3, POST /diag
end

scope "/", MyAppWeb do
  pipe_through :browser
  live "/aural/:channel_id", MyAppWeb.AuralLive, :index
end
```

```elixir
# lib/my_app_web/live/aural_live.ex
defmodule MyAppWeb.AuralLive do
  use MyAppWeb, :live_view
  alias Aural.LiveView, as: AuralLV
  alias Aural.Components, as: AuralUI

  def mount(%{"channel_id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:current_track, :serene)
     |> AuralLV.subscribe(id)}
  end

  def handle_info({:peak, _} = msg, socket), do: AuralLV.on_peak(msg, socket)

  def handle_event("aural:pick_track", %{"track" => t}, socket),
    do: AuralLV.pick_track(socket, t)

  def handle_event("aural:fire", %{"kind" => k}, socket),
    do: AuralLV.fire(socket, k)

  def render(assigns) do
    ~H"""
    <article id="aural-page" phx-hook="Aural">
      <AuralUI.audio_elements channel_id={@aural_channel} />
      <AuralUI.scope class="w-full h-32 text-violet-500" />
      <AuralUI.toggle_button class="...host styling...">
        <:label>Play</:label>
      </AuralUI.toggle_button>
      <AuralUI.status class="text-sm">Click a track to play</AuralUI.status>
      <%!-- track + chime buttons go in your host's design --%>
    </article>
    """
  end
end
```

```js
// assets/js/app.js
import {createAuralHook} from "aural"
// LiveSocket hooks:
hooks: {Aural: createAuralHook()}
```

```js
// assets/tailwind.config.js
content: [
  // ...existing entries
  "../deps/aural/lib/**/*.{ex,heex}"   // git+sparse consumers
  // "../packages/aural/lib/**/*.{ex,heex}"  // path-dep consumers
]
```

Requires `ffmpeg` on `PATH` (LAME MP3 encoder).

## Channel model

Channels are keyed by an opaque `channel_id` (URL-safe, 1-64
chars). The bare `/aural` URL the `aural_routes()` macro mounts
generates a fresh ID and 302s to `/aural/<id>`, so every visitor
lands on a unique sharable channel.

* **Lazy start.** First call to any `Aural.Channel.*` function for
  a given ID spawns the channel under the package's supervisor.
* **Fan-out.** Multiple HTTP listeners on `/aural/:id/stream.mp3`
  share one encoder and hear the same byte at the same moment.
* **Idle reap.** Channel with zero subscribers for
  `:idle_timeout_seconds` (default 300) self-terminates. Visiting
  the URL again respawns a fresh channel under the same ID.

## Public API

```elixir
Aural.Channel.new_id()                        # => "k3J9_aB2xY8"
Aural.Channel.ensure_started(channel_id)      # lazy spawn (idempotent)
Aural.Channel.list()                          # [{channel_id, pid}, ...]
Aural.Channel.valid_channel_id?(id)           # boolean
Aural.Channel.subscribe(channel_id)           # MP3 bytes
Aural.Channel.subscribe_peaks(channel_id)     # 10 Hz amplitude
Aural.Channel.pick_track(channel_id, track)   # crossfades over 3s
Aural.Channel.set_activity(channel_id, level) # tweens over ~1s
Aural.Channel.fire(channel_id, kind)          # chime: done | attention | alert
Aural.Channel.state(channel_id)               # %{track:, activity:}
```

`Aural.Components` (HEEx): `<.audio_elements channel_id>`,
`<.scope class>`, `<.toggle_button>`, `<.status>`.

`Aural.LiveView` (helpers, not a `use` macro): `subscribe/2`,
`on_peak/2`, `pick_track/2`, `set_activity/2`, `fire/2`.

`Aural.Router`: `aural_routes/0` macro for the stream + diag +
bare-entry-redirect mounts.

## Tracks

| Category | Track | Description |
|---|---|---|
| Baseline | `:serene` | Warm major7 pads, 0.1 Hz breath rhythm |
| Baseline | `:nocturne` | Dark minor, slow, deep bass |
| Baseline | `:cascade` | Rotating chord, gentle upward motion |
| Baseline | `:hum` | Brown-noise masking floor + sub-bass drone |
| Baseline | `:pink` | 1/f noise (Voss-McCartney) — tinnitus masker + sleep aid |
| Experimental | `:gamma` | Serene + 40 Hz AM (gamma entrainment claim) |
| Experimental | `:resonance` | Overt 0.1 Hz breath pacer (HRV biofeedback) |
| Experimental | `:theta` | Serene + 6 Hz AM (theta-band entrainment claim) |
| Experimental | `:vagal_drone` | Sub-bass-only 55/82/110 Hz drone |

Each track is a pure function `sample_at(n) :: float` under
`Aural.Tracks.*`. Adding a track: implement the `Aural.Track`
behaviour, register the atom in `Aural.Synth.@tracks`.

## Chimes

Three voices defined in `Aural.Signals`: `"done"`, `"attention"`,
`"alert"`. Calling `Aural.Channel.fire/2` adds the chime to the
channel's active list; the synth mixes it into the bed PCM
per-sample until its envelope expires (5 / 3 / 1.8 s
respectively). Smoothstep tail fadeout in the final 300 ms so the
exp decay reaches zero instead of clipping.

**Latency note:** chimes ride the MP3 stream, so the listener
hears them ~1-3 s after `fire/2` returns (browser audio buffer).
The JS hook listens for a round-trip `"fire"` event from the LV
and flashes the matching button immediately for click feedback;
the audio follows.

Per-channel chime cap: 16 concurrent. Past that, newest wins —
oldest gets clipped. Prevents unbounded state growth.

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:aural, :channel, :start]` | `system_time` | `channel_id` |
| `[:aural, :channel, :stop]` | `idle_ms` | `channel_id, reason` |
| `[:aural, :channel, :fire]` | `active_chimes` | `channel_id, kind` |
| `[:aural, :channel, :pick_track]` | `elapsed_chunks` | `channel_id, from, to, reversed` |
| `[:aural, :channel, :set_activity]` | `level` | `channel_id` |

Attach handlers via `:telemetry.attach/4` in the host's
application boot.

## Configuration

```elixir
config :aural,
  pubsub: MyApp.PubSub,           # required
  idle_timeout_seconds: 300       # default 5 min
```

## DOM contract

The JS hook keys off these IDs (use `Aural.Components` to get them
right):

* `phx-hook="Aural"` on a root element with `id="aural-page"`
* `#aural-audio` — streaming `<audio>` pointing at
  `/aural/:id/stream.mp3`
* `#aural-toggle`, `#aural-toggle-label`,
  `#aural-icon-play`, `#aural-icon-pause` — play/pause button
* `#aural-status` — text span the hook writes into
* `#aural-scope-line` — `<path>` inside the `#aural-scope` SVG;
  the hook sets its `d` attribute with a Catmull-Rom smoothed
  envelope of channel peaks, sub-frame-interpolated and edge-
  faded via the SVG mask `Aural.Components.scope` ships
* Buttons with `phx-click="aural:fire" phx-value-kind="..."` get
  flashed by the hook when the LV pushes the round-trip
  `"fire"` event
* Buttons with `phx-click="pick_track" phx-value-track="..."`
  trigger playback in the same gesture tick (Safari rejects
  `.play()` if a server round-trip happens between the click and
  the call)

## Tests

```
$ mix test packages/aural/test
47 tests, 0 failures
```

Channel tests are integration — they spawn real `ex_webrtc`-free
`GenServer` channels under the supervisor and need `ffmpeg` on
`PATH`. Tagged `:ffmpeg` for future skip-if-missing if needed.
