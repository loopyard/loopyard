import Config

config :loopyard,
  generators: [timestamp_type: :utc_datetime]

# Agent harness: drive the REAL Claude Code harness IN-CONTAINER over ACP. This
# is the ONLY production backend — the container is the security boundary, so a
# harness never runs on the host. The host-execution backend (Harness.Claude,
# SDK/CLI-on-host) was deleted; test.exs overrides this to `Harness.Fake`.
#
# Trade-off to know: claude-code-acp does not yet surface token usage, so cost
# telemetry reads $0 for ACP agents (IMPROVEMENTS.md #16). Permissions are
# :auto_allow — the container sandbox is trusted as the boundary, so the agent
# runs with dangerously_skip_permissions inside it.
config :loopyard, default_harness: Loopyard.Harness.ACP

# Harness model context-window sizes (tokens). Keys double as
# `String.starts_with?` prefixes, so dated variants match the base entry. This
# lives in config (not a compiled module attribute) so a new frontier-model
# release is a one-line edit, not a code change. An UNLISTED model logs loudly
# and assumes :model_window_default rather than silently miscomputing (which is
# what hid a 6x context overflow as "603% full").
config :loopyard,
  model_window_default: 200_000,
  model_windows: %{
    "claude-opus-4-8" => 1_000_000,
    "claude-opus-4-7" => 1_000_000,
    "claude-opus-4-6" => 1_000_000,
    "claude-opus-4-5" => 1_000_000,
    "claude-sonnet-4-6" => 200_000,
    "claude-sonnet-4-5" => 200_000,
    "claude-haiku-4-5" => 200_000,
    # Codex / GPT frontier — add real numbers as they ship.
    "gpt-5" => 400_000,
    "o4" => 200_000
  }

# Aural broadcasts on the host's PubSub. Without this, every
# subscriber/broadcast call raises on first use.
config :aural, pubsub: Loopyard.PubSub

# Run ONLY the os_mon subsystem we actually read.
#
# `:memsup` backs SystemStats.memory/0 on non-macOS hosts — keep it.
# Nothing anywhere reads `:disksup` or `:cpu_sup`, and both are pure
# console noise:
#
#   * disksup alarms on EVERY mounted filesystem. On a dev Mac that
#     means Time Machine backup volumes, /Volumes/.timemachine snapshot
#     mounts, and Docker's installer temp dir — 21 multi-line
#     `:alarm_handler: {:set, {{:disk_almost_full, …}}}` notices that
#     buried the 4 real boot lines under ~80 lines of output. Loopyard
#     has no stake in whether a read-only backup mount is full.
#   * cpu_sup contributes only "[os_mon] cpu supervisor port (cpu_sup):
#     Erlang has closed" on every VM shutdown, including every test run.
#
# This silences the REPORTING, not a real condition: genuine disk
# pressure on the volume we care about still shows up where it belongs
# (Health / /system), and nothing here changes free space.
config :os_mon,
  start_disksup: false,
  start_cpu_sup: false

config :loopyard, LoopyardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LoopyardWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Loopyard.PubSub,
  live_view: [signing_salt: "hive_salt_1234"]

config :esbuild,
  version: "0.17.11",
  loopyard: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --loader:.css=css),
    cd: Path.expand("../assets", __DIR__),
    # `packages` joins `deps` so Mix path deps (e.g. :aural) can be
    # imported by name. esbuild resolves `import "aural"` →
    # packages/aural/package.json → priv/assets/aural.js.
    env: %{
      "NODE_PATH" => Path.expand("../deps", __DIR__) <> ":" <> Path.expand("../packages", __DIR__)
    }
  ]

config :tailwind,
  version: "3.4.3",
  loopyard: [
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

# Redact secret-bearing params from request/event logs. "password" is Phoenix's
# default; "secret" covers the `request_secret` masked field so a submitted key
# never lands in the dev log.
config :phoenix, :filter_parameters, ["password", "secret"]

# Use system-installed claude CLI instead of bundled version
config :claude_code, cli_path: :global

import_config "#{config_env()}.exs"
