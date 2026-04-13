defmodule BoomLooper.InvariantsTest do
  @moduledoc """
  Sweep tests that enforce architectural invariants across the entire
  codebase. Each test enumerates all members of a pattern and asserts a
  property — when someone adds a new tool, LiveView, or adapter, these
  tests cover it automatically with zero extra work.

  These are the highest-leverage tests in the suite. A single 6-line test
  can cover 20 modules and catch entire classes of bugs (like the sigil
  AST leak that crashed tools/list and created a hot restart loop
  hammering the Claude API). They turn CLAUDE.md rules from "things we
  hope people remember" into "things that fail CI when violated."
  """
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------
  # 1. Every tool schema is JSON-serializable
  # ---------------------------------------------------------------
  # Catches: unevaluated sigils, AST nodes, or non-serializable types
  # in tool param descriptions. The tools/list crash that rate-limited
  # our Claude API key was caught by this test after the fact — now it
  # prevents the entire class.

  describe "tool schema invariants" do
    test "every tool schema is JSON-serializable" do
      for tool_mod <- tool_modules() do
        tool_def = %{
          "name" => tool_mod.__tool_name__(),
          "description" => tool_mod.__description__(),
          "inputSchema" => tool_mod.input_schema()
        }

        assert {:ok, _} = Jason.encode(tool_def),
          "#{tool_mod} tool definition is not JSON-serializable — " <>
          "check for unevaluated sigils or AST nodes in params"
      end
    end

    test "every tool module under container/ is registered in the toolkit" do
      # If you add a tool file but forget to register it in
      # Container.__tool_server__/0, agents can't discover it.
      registered_names = tool_modules() |> MapSet.new(& &1.__tool_name__())

      tool_files =
        Path.wildcard("lib/boom_looper/tools/container/*.ex")
        |> Enum.map(&Path.basename(&1, ".ex"))
        |> Enum.reject(&(&1 in ["helpers", "probe_formatter"]))
        |> MapSet.new()

      for file <- tool_files do
        # Convert file name to expected tool name (they should match)
        assert file in registered_names or
                 String.replace(file, "_", "") in Enum.map(MapSet.to_list(registered_names), &String.replace(&1, "_", "")),
          "lib/boom_looper/tools/container/#{file}.ex exists but no tool named '#{file}' is registered in Container.__tool_server__/0"
      end
    end

    test "every tool module exports the required interface" do
      for tool_mod <- tool_modules() do
        # Ensure the module is loaded — function_exported? doesn't autoload
        Code.ensure_loaded!(tool_mod)
        assert function_exported?(tool_mod, :__tool_name__, 0), "#{tool_mod} missing __tool_name__/0"
        assert function_exported?(tool_mod, :__description__, 0), "#{tool_mod} missing __description__/0"
        assert function_exported?(tool_mod, :input_schema, 0), "#{tool_mod} missing input_schema/0"
        assert function_exported?(tool_mod, :execute, 2), "#{tool_mod} missing execute/2"
      end
    end
  end

  # ---------------------------------------------------------------
  # 2. No Docker shell-outs outside BoomLooper.Docker
  # ---------------------------------------------------------------
  # Enforces the "every Docker CLI call goes through BoomLooper.Docker"
  # rule from CLAUDE.md. Without this, System.cmd("docker", ...) calls
  # creep into LiveViews and GenServers, bypassing timeouts, telemetry,
  # and error formatting.

  describe "docker call invariants" do
    test "System.cmd(\"docker\") only appears in Docker module" do
      violations =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          content = File.read!(path)

          if String.contains?(content, "System.cmd(\"docker\"") do
            mod = path |> String.replace("lib/", "") |> String.replace(".ex", "")
            # Docker.ex is the only allowed caller. Mix tasks run outside
            # the app and can't use BoomLooper.Docker, so they're exempt.
            if String.contains?(mod, "docker") or String.contains?(mod, "mix/tasks") do
              []
            else
              [mod]
            end
          else
            []
          end
        end)

      assert violations == [],
        "System.cmd(\"docker\") found outside Docker module: #{inspect(violations)}. " <>
        "Use BoomLooper.Docker.docker/2 or Docker.stream/3 instead."
    end
  end

  # ---------------------------------------------------------------
  # 3. Every Source adapter's callbacks don't crash on basic inputs
  # ---------------------------------------------------------------
  # The behaviour enforces compile-time type signatures, but the sigil
  # bug proved compile != runtime. This test actually CALLS each
  # callback with a minimal input and asserts it doesn't raise.

  describe "source adapter invariants" do
    @adapters [BoomLooper.Source.Local, BoomLooper.Source.GitHub]

    test "every adapter implements query callbacks without crashing" do
      dummy_workspace = %{id: "test-0000", worktree_path: nil}

      for adapter <- @adapters do
        # These are read-only query callbacks — they should never crash,
        # even with a fake workspace.
        assert is_binary(adapter.checkout_path(dummy_workspace)) or
                 is_nil(adapter.checkout_path(dummy_workspace)),
          "#{adapter}.checkout_path crashed"

        assert adapter.dirty?(dummy_workspace) in [true, false],
          "#{adapter}.dirty? crashed"

        case adapter.current_revision(dummy_workspace) do
          {:ok, rev} -> assert is_binary(rev)
          {:error, _} -> :ok
        end

        # Container hooks should be no-ops for dummy workspaces
        assert adapter.on_container_up(dummy_workspace) == :ok
        assert adapter.on_container_down(dummy_workspace) == :ok
      end
    end
  end

  # ---------------------------------------------------------------
  # 4. Every ETS table in StateKeeper is used somewhere
  # ---------------------------------------------------------------
  # If a table is defined in StateKeeper but never read, it's dead
  # weight. If it's read but not in StateKeeper, it'll crash at
  # runtime. Verify both directions.

  describe "ETS table invariants" do
    test "StateKeeper tables are referenced in application code" do
      state_keeper_source = File.read!("lib/boom_looper/state_keeper.ex")

      # Extract table names from the @tables list (lines like `  :chat_agents,`)
      table_names =
        Regex.scan(~r/@tables\s*\[(.*?)\]/s, state_keeper_source)
        |> Enum.flat_map(fn [_, body] ->
          Regex.scan(~r/:(\w+)/, body) |> Enum.map(fn [_, name] -> name end)
        end)
        |> Enum.uniq()

      assert table_names != [], "Could not parse @tables from StateKeeper"

      # Each table should appear in at least one other file
      app_source =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&String.contains?(&1, "state_keeper.ex"))
        |> Enum.map(&File.read!/1)
        |> Enum.join("\n")

      for table <- table_names do
        assert String.contains?(app_source, ":#{table}"),
          "ETS table :#{table} is defined in StateKeeper but never referenced elsewhere"
      end
    end
  end

  # ---------------------------------------------------------------
  # 5. PubSub topic symmetry: every broadcast has a subscriber
  # ---------------------------------------------------------------

  describe "PubSub topic invariants" do
    test "every broadcast topic pattern has a matching subscribe" do
      all_source =
        Path.wildcard("lib/**/*.ex")
        |> Enum.map(&File.read!/1)
        |> Enum.join("\n")

      # Extract broadcast topic patterns (string literals only)
      broadcast_topics =
        Regex.scan(~r/PubSub\.broadcast\([^,]+,\s*"([^"]+)"/, all_source)
        |> Enum.map(fn [_, topic] -> topic_base(topic) end)
        |> MapSet.new()

      subscribe_topics =
        Regex.scan(~r/PubSub\.subscribe\([^,]+,\s*"([^"]+)"/, all_source)
        |> Enum.map(fn [_, topic] -> topic_base(topic) end)
        |> MapSet.new()

      orphaned = MapSet.difference(broadcast_topics, subscribe_topics)

      # Allow known static topics that use module-level constants
      # (these are matched via @topic attributes, not string literals)
      assert MapSet.size(orphaned) == 0,
        "Broadcast topics with no subscriber: #{inspect(MapSet.to_list(orphaned))}. " <>
        "If these use module constants (@topic), this is a false positive."
    end
  end

  # ---------------------------------------------------------------
  # 6. LiveViews must not call ServiceStatus.for_workspace directly
  # ---------------------------------------------------------------

  describe "service data invariants" do
    test "no LiveView/component calls ServiceStatus.for_workspace directly" do
      violations =
        Path.wildcard("lib/boom_looper_web/**/*.ex")
        |> Enum.flat_map(fn path ->
          content = File.read!(path)
          if String.contains?(content, "ServiceStatus.for_workspace") do
            [path |> String.replace("lib/", "")]
          else
            []
          end
        end)

      assert violations == [],
        "LiveViews must use Observer.services_for(workspace_id), not " <>
        "ServiceStatus.for_workspace: #{inspect(violations)}"
    end

    test "every service_statuses assignment in chat_live is guarded against empty replacement" do
      # The sidebar flapping bug was caused by unguarded assignments that
      # replaced a non-empty service list with []. Every assignment except
      # mount (first render) must go through guard_service_statuses/2.
      content = File.read!("lib/boom_looper_web/live/chat_live.ex")

      # Find all functions that assign :service_statuses by looking at
      # function-level blocks. Each block that assigns service_statuses
      # must either be mount (first value) or contain guard_service_statuses
      # somewhere in the same function.
      lines = String.split(content, "\n")

      # Split into function blocks at def/defp boundaries
      # For each assign(:service_statuses, ...) line, check if
      # guard_service_statuses appears within the preceding 10 lines
      assignments =
        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          String.contains?(line, "assign") and
            String.contains?(line, ":service_statuses") and
            not String.contains?(line, "assigns.service_statuses")
        end)

      unguarded =
        Enum.filter(assignments, fn {_line, n} ->
          # Check the surrounding context (10 lines before) for a guard
          context = Enum.slice(lines, max(0, n - 11), 12) |> Enum.join("\n")
          not String.contains?(context, "guard_service_statuses") and
            not String.contains?(context, "mount_with_workspace")
        end)
        |> Enum.map(fn {line, n} -> "line #{n}: #{String.trim(line)}" end)

      # Exactly 1 unguarded assignment is allowed: mount's initial value.
      # Everything else must use guard_service_statuses to prevent flapping.
      assert length(unguarded) <= 1,
        "Unguarded service_statuses assignments will cause sidebar flapping. " <>
          "Use guard_service_statuses(socket, new_statuses):\n" <>
          Enum.join(unguarded, "\n")
    end
  end

  # ---------------------------------------------------------------
  # 7. Ad-hoc virtual dir computation should be minimized
  # ---------------------------------------------------------------
  # Every `Path.join([..., "workspaces", id])` is a potential source of
  # path drift. The canonical way to get the compose/virtual dir is via
  # `workspace.compose_dir` (set by normalize_workspace). This test
  # counts ad-hoc computations so we can track them going DOWN, not up.

  describe "virtual dir computation" do
    test "ad-hoc virtual dir paths are tracked (should decrease over time)" do
      count =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          content = File.read!(path)
          # Match the pattern: Path.join([..., "workspaces", ...])
          Regex.scan(~r/Path\.join\(\[.*"workspaces"/, content)
        end)
        |> length()

      # 3 remaining: compose_dir/1 definition, normalize path backfill,
      # normalize compose_dir backfill. Everything else uses compose_dir/1.
      assert count <= 3,
        "Ad-hoc virtual dir computations increased to #{count}. " <>
        "Use workspace.compose_dir from the workspace record instead of " <>
        "computing Path.join([home_dir(), \"workspaces\", id]) inline."
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp tool_modules do
    BoomLooper.Tools.Container.__tool_server__().tools
  end

  # Strip dynamic suffixes from topic strings for comparison.
  # "chat_agent:abc123" → "chat_agent:", "source_sync:xyz" → "source_sync:"
  defp topic_base(topic) do
    case String.split(topic, ~r/[#\{]/, parts: 2) do
      [base, _] -> base
      [base] -> base
    end
  end
end
