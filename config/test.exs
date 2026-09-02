import Config

# The test home must be redirected and reset HERE, not in test_helper.exs.
# `mix test` starts the :loopyard application BEFORE it evaluates
# test_helper.exs, and boot immediately reads projects.json and replays
# every workspace's agents.log (Application.restore_all_agents/0). Doing
# this in test_helper left that whole boot window pointed at the
# developer's real ~/.loopyard — which is how ~100 dead test agents
# (backoff-test-*, resume-test-*, …) ended up permanently written into
# real workspace logs, warning on every boot thereafter. Config files are
# evaluated before app start, so this closes the window.
loopyard_test_home = Path.join(File.cwd!(), ".loopyard_home")
System.put_env("LOOPYARD_HOME", loopyard_test_home)

# Start every run from an empty home. Nothing in here is a fixture — tests
# create projects and workspaces with random ids and never remove them, so
# this grew without bound (1723 workspace dirs / 3117 agents.log files /
# 73MB before this landed) and every boot replayed the residue: dead test
# agents as "no {:agent, …} identity record" warnings, dead temp dirs as
# "Failed to restore project" warnings.
File.rm(Path.join(loopyard_test_home, "projects.json"))
File.rm_rf!(Path.join(loopyard_test_home, "workspaces"))
File.mkdir_p!(loopyard_test_home)

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
# The inbox store keeps no log in tests: items would replay across runs
# (stale agents, colliding ids) and pollute every deck test.
config :loopyard, notifications_log?: false

# Harness memory monitor runs `docker stats` sweeps + restarts bloated agents —
# meaningless (and Docker-dependent) in tests. :ignore so no child even starts.
config :loopyard, harness_memory_monitor_enabled?: false

# Docker names are global; LOOPYARD_HOME only scopes files. Without its own
# prefix the suite addresses — and overwrites — the developer's live identity
# container and home volume. See Loopyard.Workstation.resource_prefix/0.
config :loopyard, resource_prefix: "loopyard-test-"

# The backstop behind the prefix: naming a REAL Docker resource from a test
# raises at the call. See Loopyard.Docker.prefix/0.
config :loopyard, forbid_real_docker_resources: true

# The default suite does not talk to the Docker daemon: shelling out is slow,
# depends on what happens to be running on this machine, and blew the
# 2s-per-test budget in unrelated tests. A run that actually exercises the
# :docker-tagged tests opts in via env — `LOOPYARD_DOCKER_TESTS=1 mix test
# --include docker` locally, and CI's docker-e2e job sets it. (The tag alone
# can't flip this: app env is global, so per-test put_env would leak into
# concurrently running untagged tests.)
config :loopyard, docker_enabled: System.get_env("LOOPYARD_DOCKER_TESTS") in ["1", "true"]

# Chat attachments write into a fake on-disk "volume" (see
# Loopyard.Test.FakeAttachmentWriter) — the real writer is `docker cp`.
config :loopyard, attachment_writer: Loopyard.Test.FakeAttachmentWriter
config :loopyard, container_io: Loopyard.Test.FakeContainerIO

# Timing knobs the default suite shrinks (production keeps the module
# defaults): the SyncMonitor readiness probe (200ms × 5 attempts = 0.8s of
# pure waiting in one test) and the warm-interrupt deadline (1.5s before a
# wedged cancel_turn is given up on — the test only needs the give-up).
config :loopyard,
  sync_ready_probe_ms: 5,
  interrupt_deadline_ms: 200,
  rate_limit_retry_grace_ms: 50
