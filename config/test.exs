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
  # Turn auto-retry OFF suite-wide: tests fabricate turn failures constantly,
  # and the prod default (3 retries w/ backoff) would leave those agents
  # :thinking on scheduled retries — cascading timeouts across the suite.
  # turn_retry_test deletes this env in the ONE test that pins the prod
  # default, and restores it in on_exit.
  agent_turn_retries: 0,
  # No Docker-daemon probing/healing in tests (the keeper GenServer starts
  # but never ticks; tests drive transitions via the injected probe/heal fns).
  docker_probe_ms: nil,
  # Disable Saga.Journal writes by default in test env. Async saga
  # tests would otherwise share one journal file and race on
  # compaction. Tests that exercise the journal explicitly opt in via
  # `Saga.run/2` with `journal?: true` (journal_test.exs does this).
  saga_journal_default: false

config :loopyard, activity_sound: false

# No dedicated MCP listener in tests — the plug is exercised directly, and a
# real 0.0.0.0 Bandit listener would race across async runs on a fixed port.
config :loopyard, :acp_mcp_listener, enabled: false

# The send-path wake (wake_and_enqueue) is a LIVE-system feature: it boots
# real supervisors/agents (and possibly docker compose). In tests those side
# effects wedge the shared WorkspaceSupervisor and slow every teardown, so a
# send to a dead agent gets the instant :unavailable instead. Tests exercising
# the wake explicitly can flip this on.
config :loopyard, send_wakes_agent?: false

# ChangeCounts recomputes run real git shell-outs against workspaces on agent
# StatusChanged events — meaningless churn against synthetic test workspaces.
# The GenServer starts but stays inert (no subscription, no sweep, no tasks).
config :loopyard, change_counts_enabled?: false
config :loopyard, operator_digest_enabled?: false

# Harness memory monitor runs `docker stats` sweeps + restarts bloated agents —
# meaningless (and Docker-dependent) in tests. :ignore so no child even starts.
config :loopyard, harness_memory_monitor_enabled?: false
