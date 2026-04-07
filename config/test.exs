import Config

config :boom_looper, BoomLooperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_hive_application_test",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :enable_expensive_runtime_checks, true

# Disable auth in tests by default
# Clone mode: :sync (default), :async, :disabled
config :boom_looper,
  auth_password: nil,
  auth_username: nil,
  clone_mode: :disabled
