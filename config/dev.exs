import Config

config :hive, HiveWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_that_is_at_least_64_bytes_long_for_hive_application_dev_mode",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:hive, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:hive, ~w(--watch)]}
  ]

config :hive, HiveWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/hive_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
