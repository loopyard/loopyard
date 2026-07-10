import Config

config :loopyard, LoopyardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_that_is_at_least_64_bytes_long_for_hive_application_test",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :enable_expensive_runtime_checks, true

# Disable auth in tests by default
# Clone mode: :sync (default), :async, :disabled
config :loopyard,
  auth_password: nil,
  auth_username: nil,
  clone_mode: :disabled,
  # Default every ChatAgent in tests to a no-op backend so we never
  # accidentally spawn the real Claude CLI subprocess. Individual
  # tests can still pass `backend: SomeOther` in opts to override.
  default_harness: Loopyard.Harness.Fake,
  # Disable Saga.Journal writes by default in test env. Async saga
  # tests would otherwise share one journal file and race on
  # compaction. Tests that exercise the journal explicitly opt in via
  # `Saga.run/2` with `journal?: true` (journal_test.exs does this).
  saga_journal_default: false

config :loopyard, activity_sound: false
