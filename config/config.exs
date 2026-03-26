import Config

config :boom_looper,
  generators: [timestamp_type: :utc_datetime]

config :boom_looper, BoomLooperWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BoomLooperWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: BoomLooper.PubSub,
  live_view: [signing_salt: "hive_salt_1234"]

config :esbuild,
  version: "0.17.11",
  boom_looper: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --loader:.css=css),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  boom_looper: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Use system-installed claude CLI instead of bundled version
config :claude_code, cli_path: :global

import_config "#{config_env()}.exs"
