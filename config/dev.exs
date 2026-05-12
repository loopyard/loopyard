import Config

# Loopback by default. Operator opts in via /connect → Expose, which restarts
# the endpoint bound to 0.0.0.0. See Loopyard.HostExposer.
config :loopyard, LoopyardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_that_is_at_least_64_bytes_long_for_hive_application_dev_mode",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:loopyard, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:loopyard, ~w(--watch)]}
  ]

config :loopyard, LoopyardWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/loopyard_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
