# Aural

Cerebral ambient audio bed for Phoenix apps. One always-on synth +
ffmpeg pipeline broadcasts MP3 chunks via `Phoenix.PubSub` to every
HTTP listener. Chime alerts fire as preloaded WAVs in the browser for
~WS-RTT latency — they bypass the streaming buffer entirely.

Designed to sit beneath a future audio-signaling layer: gentle
non-musical alerts that don't compete with the bed.

## Wiring it into a host app

```elixir
# mix.exs
{:aural, git: "https://github.com/bradgessler/loopyard.git",
         sparse: "packages/aural"}
```

```elixir
# config/config.exs — Aural broadcasts on the host's PubSub
config :aural, pubsub: MyApp.PubSub
```

```elixir
# lib/my_app/application.ex — start the Channel after PubSub
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  Aural.Channel,
  # ...
]
```

```elixir
# lib/my_app_web/router.ex
scope "/", MyAppWeb do
  pipe_through :browser
  live "/aural", AuralWeb.Live, :index
end

pipeline :aural do
  plug :accepts, ["*/*", "json", "html", "mpeg"]
end

scope "/aural" do
  pipe_through :aural
  get "/stream.mp3", AuralWeb.StreamController, :stream
  post "/diag", AuralWeb.StreamController, :diag
end
```

```elixir
# lib/my_app_web/endpoint.ex — serve the chime WAVs
plug Plug.Static,
  at: "/chimes",
  from: {:aural, "priv/static/chimes"},
  gzip: false
```

```js
// assets/js/app.js
import {createAuralHook} from "aural"
Hooks.Aural = createAuralHook()
```

```js
// assets/tailwind.config.js — include the library's templates
content: [
  // ...existing entries
  "../deps/aural/lib/**/*.{ex,heex}"
]
```

Requires `ffmpeg` on `PATH`.
