# Ambient Soundtrack — generative audio in pure Elixir

## Why

Loopyard's whole experience benefits from being a place you *inhabit*
while you work. A subtle generative ambient soundtrack reinforces that
— the room hums quietly while agents work, you record a chunk for your
demo video, eventually the music reacts to what's happening in the
system. Same multiplayer model as the rest of Loopyard: everyone
connected hears the same audio at the same time.

Architectural insight that makes this fit Loopyard rather than feel
bolted on: the audio engine is just another GenServer that broadcasts
on PubSub. Tracks are compositions written as Elixir functions.
Instruments are pure functions. System events are inputs that can
later feed track parameters. Same patterns the rest of the codebase
uses.

## Scope

**MVP (this plan):**
- Multiple selectable tracks, each a self-contained composition.
- Tracks run steady — no system reactivity yet, but the input plumbing
  is in place so reactivity is a one-line wire-up later.
- Browser plays via WebAudio. ~40 lines of JS (dumb player only).
- All audio generation in Elixir.
- Per-user track selection (which track is playing), start/stop.

**Not in this plan:**
- System-event-driven reactivity (the inputs are there; nothing's
  wired to them yet).
- Audio codec compression (raw 16-bit PCM is fine at Loopyard's scale).
- Dynamics compression / limiter (ambient voices stay soft by design).
- Cross-device sync beyond what PubSub naturally provides (~50ms drift
  between browsers is fine for ambient).
- Recording to file as a UI feature (browser users can capture with
  OBS/system audio; a `mix loopyard.ambient.record` task can be added
  later if needed).

## Directory layout

```
lib/loopyard/ambient/
  engine.ex                  # GenServer: ticks, calls active track, broadcasts chunks
  primitive.ex               # Pure: sine/2, saw/2, env_adsr/4, mix/2, render_chunk/4
  instrument.ex              # Behaviour: voice/3
  instruments/
    pad.ex                   # Soft sustained chord voice
    chime.ex                 # Sparse plucked-bell voice
    bass.ex                  # Sub bass drone
    air.ex                   # Slowly modulated noise texture
  track.ex                   # Behaviour: name/0, voices/2
  tracks/
    serene.ex                # Default. Pad + occasional chime + bass.
    focus.ex                 # Slightly denser. Subtle motion.
    nocturne.ex              # Darker, slower. Minor key.
    arrival.ex               # Brighter. Major key, more chime.
  input.ex                   # Behaviour: sample/2
  inputs/
    constant.ex              # Always returns the same value
    pubsub.ex                # Subscribe to a Loopyard PubSub topic; map events to a value
    metric.ex                # Sample a function periodically (agent count, recent error rate, etc.)
  channel.ex                 # Phoenix Channel that pushes binary chunks to subscribers
  events.ex                  # Loopyard.Events.Ambient — publish/subscribe wrapper
assets/js/ambient.js         # Dumb WebAudio player. Receive binary, schedule playback. ~40 lines.
```

All audio code lives under `lib/loopyard/ambient/`. New instruments,
tracks, and input types are each a new file in the obvious subdir.

## Core abstractions

### Primitive — pure math

```elixir
defmodule Aural.Primitive do
  @sample_rate 44_100

  # Returns a function (t_sample -> float in [-1, 1]).
  def sine(freq, amp \\ 1.0) do
    fn n -> amp * :math.sin(2 * :math.pi * freq * n / @sample_rate) end
  end

  # Apply an ADSR envelope to a voice function.
  def env_adsr(voice_fn, attack_s, decay_s, sustain, release_s, start_n, dur_n) do
    # ... returns a new voice_fn that includes the envelope
  end

  # Mix N voice functions into one.
  def mix(voice_fns) do
    fn n -> Enum.reduce(voice_fns, 0.0, fn f, acc -> acc + f.(n) end) end
  end

  # Render a chunk of N samples from a voice_fn starting at time t.
  # Returns a 16-bit LE PCM binary.
  def render_chunk(voice_fn, t, chunk_size) do
    for i <- 0..(chunk_size - 1), into: <<>> do
      sample = voice_fn.(t + i) |> clamp(-1.0, 1.0)
      <<round(sample * 32_767)::little-signed-16>>
    end
  end
end
```

### Instrument — voice-builder

```elixir
defmodule Aural.Instrument do
  @callback voice(notes :: [number], t :: integer, opts :: map) :: (integer -> float)
end

defmodule Aural.Instruments.Pad do
  @behaviour Aural.Instrument
  alias Aural.Primitive

  def voice(notes, t, opts) do
    gain = Map.get(opts, :gain, 0.3)
    notes
    |> Enum.map(&Primitive.sine(&1, gain / length(notes)))
    |> Primitive.mix()
  end
end
```

### Track — composition

```elixir
defmodule Aural.Track do
  @callback name() :: String.t()
  @callback inputs() :: %{atom => {module, term}}  # default input bindings
  @callback voices(t :: integer, inputs :: map) :: (integer -> float)
end

defmodule Aural.Tracks.Serene do
  @behaviour Aural.Track
  alias Aural.{Primitive, Instruments.Pad, Instruments.Chime, Instruments.Bass}
  alias Aural.Inputs.Constant

  def name, do: "serene"

  def inputs do
    %{
      density:    {Constant, 0.3},
      brightness: {Constant, 0.5}
    }
  end

  def voices(t, inputs) do
    chord = chord_at(t)  # progression cycles every ~60s

    [
      Pad.voice(chord, t, %{gain: 0.4, brightness: inputs.brightness}),
      Bass.voice([List.first(chord) / 2], t, %{gain: 0.3}),
      maybe_chime(chord, t, inputs.density)
    ]
    |> Enum.reject(&is_nil/1)
    |> Primitive.mix()
  end

  defp chord_at(t), do: ...  # internal harmonic schedule
  defp maybe_chime(chord, t, density), do: ...  # density gates how often
end
```

### Input — streams of values

```elixir
defmodule Aural.Input do
  @callback sample(state :: any, t :: integer) :: {value :: number, state}
end

defmodule Aural.Inputs.Constant do
  @behaviour Aural.Input
  def sample(value, _t), do: {value, value}
end

defmodule Aural.Inputs.PubSub do
  @behaviour Aural.Input
  # State: {topic, map fn, current_value}. Subscribes on init,
  # accumulates events into the value via the map fn.
  def sample({_topic, _fn, value} = state, _t), do: {value, state}
end
```

### Engine — the runtime

```elixir
defmodule Aural.Engine do
  use GenServer

  @chunk_size 2048   # ~46ms at 44.1kHz
  @tick_ms 46

  def play(track_name), do: GenServer.cast(__MODULE__, {:play, track_name})
  def stop, do: GenServer.cast(__MODULE__, :stop)
  def attach_input(input_name, {module, init_arg}),
    do: GenServer.cast(__MODULE__, {:attach_input, input_name, {module, init_arg}})

  def handle_info(:tick, %{playing?: true} = state) do
    {inputs, state} = sample_inputs(state)
    voice_fn = state.track.voices(state.t, inputs)
    chunk = Primitive.render_chunk(voice_fn, state.t, @chunk_size)
    Events.Ambient.broadcast_chunk(chunk)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | t: state.t + @chunk_size}}
  end
end
```

### Channel + player

```elixir
defmodule Aural.Channel do
  use Phoenix.Channel

  def join("ambient:lobby", _, socket) do
    Events.Ambient.subscribe()
    {:ok, socket}
  end

  def handle_info({:audio_chunk, bin}, socket) do
    push(socket, "chunk", {:binary, bin})
    {:noreply, socket}
  end
end
```

```js
// assets/js/ambient.js — the entire JS surface
const ctx = new AudioContext({sampleRate: 44100})
let nextStart = 0

const channel = socket.channel("ambient:lobby")
channel.join()
channel.on("chunk", payload => {
  const samples = new Int16Array(payload)
  const floats = Float32Array.from(samples, s => s / 32768)
  const buf = ctx.createBuffer(1, floats.length, 44100)
  buf.copyToChannel(floats, 0)
  const src = ctx.createBufferSource()
  src.buffer = buf
  src.connect(ctx.destination)
  src.start(Math.max(nextStart, ctx.currentTime + 0.05))
  nextStart = Math.max(nextStart, ctx.currentTime + 0.05) + buf.duration
})

document.getElementById("aural-toggle")?.addEventListener("click", () => {
  ctx.resume()  // satisfies browser autoplay policy
})
```

## How tracks listen to system events (deferred but pre-wired)

When you want to make `serene` get denser when agents are active:

```elixir
# Anywhere, once:
Aural.Engine.attach_input(:density, {
  Aural.Inputs.PubSub,
  topic: "chat_agents",
  map_fn: fn _events_in_last_5s, n -> min(n / 10, 1.0) end
})
```

No engine changes. No track changes. Just plug a different input
source for `:density` and the music responds. This is the whole
point of separating tracks (composition) from inputs (data sources).

## Implementation order

1. **Primitives + a single instrument + a single track.** No PubSub
   yet, no channel. `Aural.Engine.test_render(:serene)`
   produces a 5-second WAV file you can play locally. Confirms the
   math works.
2. **Engine GenServer + PubSub broadcast + channel + JS player.**
   First end-to-end: pick a track, hear it in the browser.
3. **More tracks.** Focus, Nocturne, Arrival. Each is a new file in
   `tracks/`. The instrument set stays small (~4 instruments).
4. **Track switcher UI.** Small control somewhere (sidebar? `/ambient`
   page?) — pick a track, mute/unmute. Per-user prefs in localStorage.
5. **Input plumbing.** `Inputs.PubSub` and `Inputs.Metric`. No tracks
   actually use these yet; the wiring just exists for whoever opts in.

Estimated effort: ~1 day for steps 1-2 (the interesting part), another
day for 3-5 (mostly UI + more tracks). Total: 2 focused days for a
real shipping feature.

## Edge cases

- **Browser autoplay policy.** First user click anywhere enables
  `ctx.resume()`. Standard.
- **Multiple browsers, same audio.** All subscribers to the
  `:ambient_audio` topic receive the same binary frames. They'll
  play within ~50ms of each other (network + browser scheduling).
  For ambient that's imperceptible.
- **No listeners.** Engine still ticks (cheap), broadcasts go to
  the void. If we want to be clever, skip the broadcast when
  `Phoenix.PubSub.broadcast_count(...)` is 0. Not worth optimizing
  for v1.
- **Engine crash.** Supervisor restarts. Audio interruption ~100ms.
  Browser's queue might run dry briefly. Acceptable.
- **Browser tab backgrounded.** AudioContext continues; browser
  may throttle the schedule timer slightly. Buffer keeps it flowing.
- **Long-running ticks.** If `render_chunk` ever takes longer than
  `@tick_ms`, audio glitches. Mitigate by keeping voice math simple
  and benchmarking the worst track. For ambient (4-6 sine voices
  with envelopes) we're well within budget.

## Open questions

- **Reverb.** No off-the-shelf in Elixir; would need a simple Schroeder
  reverb (~4 comb filters + 2 all-passes) or a delay line. ~50 lines.
  For MVP, skip — voice overlap and slow attacks give most of the
  spatial feel.
- **Stereo.** Mono is simpler (one channel). Stereo doubles bandwidth
  + sample-side complexity. Defer.
- **Per-user track choice.** All connected users hearing the same
  thing is multiplayer-coherent but means one person can't pick their
  own track. Alternative: each browser runs its own Engine instance
  via a session-scoped GenServer. More complex; defer.
- **Recording.** `mix loopyard.ambient.record --track serene --duration 5m`
  task could write a WAV file. Easy to add later — same engine, write
  to disk instead of (or in addition to) broadcasting.
- **CPU budget.** Estimated ~1% on M1. Validate on Loopyard's actual
  host before shipping multiple tracks running in parallel (not v1).

## Code rules this plan upholds

- **CODE_RULES § "Isolate logic into testable modules"** — Primitives
  are pure functions, instruments are pure functions, tracks are pure
  functions, engine is the only stateful piece. Easy to test.
- **CODE_RULES § "One source of truth per domain"** — engine owns
  the schedule + active track. Single GenServer. No racing state.
- **CODE_RULES § "Multiplayer is the default"** — every connected
  browser hears the same audio via PubSub.
- **CODE_RULES § "Never block a LiveView on Docker"** — no Docker
  involved at all.
- **docs/CODE_RULES.md** — no new env vars or commands. Default track
  picked automatically; toggle is just a UI button.

## Docs to update when this ships

- `docs/ARCHITECTURE.md` — new `Aural.*` namespace, the
  engine in the supervisor tree, the channel.
- `docs/CONFIG.md` — sample rate, chunk size, tick rate (constants
  not currently configurable, but document where they live).
- `CLAUDE.md` — mention ambient soundtrack as a UX surface alongside
  the existing multiplayer claims.
