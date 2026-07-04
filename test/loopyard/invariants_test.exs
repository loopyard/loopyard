defmodule Loopyard.InvariantsTest do
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
  # async: false — this test iterates every module under
  # `Loopyard.Tools.Container.*` and calls `__tool_name__/0`.
  # Under full-suite load with parallel compilation, that races
  # with the final loading of recently-edited tool modules,
  # producing "module is not available" errors. Serial execution
  # ensures every tool module is loaded before the invariant check
  # runs. See plans/post-migration-audit.md NOTE #14.
  use ExUnit.Case, async: false

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
        Path.wildcard("lib/loopyard/tools/container/*.ex")
        |> Enum.map(&Path.basename(&1, ".ex"))
        |> Enum.reject(&(&1 in ["helpers", "probe_formatter", "pagination"]))
        |> MapSet.new()

      for file <- tool_files do
        # Convert file name to expected tool name (they should match)
        assert file in registered_names or
                 String.replace(file, "_", "") in Enum.map(
                   MapSet.to_list(registered_names),
                   &String.replace(&1, "_", "")
                 ),
               "lib/loopyard/tools/container/#{file}.ex exists but no tool named '#{file}' is registered in Container.__tool_server__/0"
      end
    end

    test "every tool module exports the required interface" do
      for tool_mod <- tool_modules() do
        # Ensure the module is loaded — function_exported? doesn't autoload
        Code.ensure_loaded!(tool_mod)

        assert function_exported?(tool_mod, :__tool_name__, 0),
               "#{tool_mod} missing __tool_name__/0"

        assert function_exported?(tool_mod, :__description__, 0),
               "#{tool_mod} missing __description__/0"

        assert function_exported?(tool_mod, :input_schema, 0),
               "#{tool_mod} missing input_schema/0"

        assert function_exported?(tool_mod, :execute, 2), "#{tool_mod} missing execute/2"
      end
    end
  end

  # ---------------------------------------------------------------
  # 2. No Docker shell-outs outside Loopyard.Docker
  # ---------------------------------------------------------------
  # Enforces the "every Docker CLI call goes through Loopyard.Docker"
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
            # the app and can't use Loopyard.Docker, so they're exempt.
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
               "Use Loopyard.Docker.docker/2 or Docker.stream/3 instead."
    end
  end

  # ---------------------------------------------------------------
  # 3. Every Source adapter's callbacks don't crash on basic inputs
  # ---------------------------------------------------------------
  # The behaviour enforces compile-time type signatures, but the sigil
  # bug proved compile != runtime. This test actually CALLS each
  # callback with a minimal input and asserts it doesn't raise.

  describe "source adapter invariants" do
    @adapters [Loopyard.Source.Local, Loopyard.Source.GitHub]

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
      state_keeper_source = File.read!("lib/loopyard/state_keeper.ex")

      # Extract table names from the @tables list. Each entry is a
      # tuple `{:table_name, [opt1, opt2, ...]}`. The old regex picked
      # up every atom (including :named_table from the options) which
      # made the assertion fail against any option not referenced by
      # app code. Match only the FIRST atom inside each tuple.
      table_names =
        Regex.scan(~r/@tables\s*\[(.*?)\]/s, state_keeper_source)
        |> Enum.flat_map(fn [_, body] ->
          Regex.scan(~r/\{:(\w+)\s*,/, body) |> Enum.map(fn [_, name] -> name end)
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

    # The "StateKeeper is the sole ETS owner" invariant (CLAUDE.md) was
    # convention-only — nothing failed CI if someone added :ets.new
    # elsewhere, which would create a table whose lifetime is wrong (dies
    # with the wrong process) and that the reconciler/health map can't see.
    test ":ets.new is only called in StateKeeper" do
      violations =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&String.contains?(&1, "state_keeper.ex"))
        |> Enum.flat_map(fn path ->
          File.read!(path)
          |> String.split("\n")
          |> Enum.with_index(1)
          # Real calls only — skip comment lines (a few modules mention
          # :ets.new in a comment documenting their migration away from it).
          |> Enum.filter(fn {line, _} ->
            String.contains?(line, ":ets.new(") and
              not String.starts_with?(String.trim_leading(line), "#")
          end)
          |> Enum.map(fn {_, n} -> "#{path}:#{n}" end)
        end)

      assert violations == [],
             "`:ets.new` must only appear in StateKeeper (the sole ETS owner). " <>
               "Add your table to StateKeeper's @tables instead. Found: #{inspect(violations)}"
    end
  end

  # ---------------------------------------------------------------
  # Boundary-crossing guardrail: a tool that creates or destroys a
  # workspace MUST route through the human-approval broker. The
  # propose_*/Approvals wiring was convention — a new destructive tool
  # that called Onboarding/Destructor directly would skip the guardrail
  # and not trip CI. This sweep makes it enforced.
  # ---------------------------------------------------------------
  describe "approval-gating invariants" do
    test "any tool touching workspace lifecycle routes through Approvals" do
      # Functions that create/destroy a workspace — the boundary-crossing ops.
      lifecycle_call = ~r/(fork_from_workspace|Workspace\.Destructor|destroy_workspace)/

      violations =
        Path.wildcard("lib/loopyard/tools/**/*.ex")
        |> Enum.filter(fn path ->
          src = File.read!(path)

          Regex.match?(lifecycle_call, src) and
            not String.contains?(src, "Approvals.request")
        end)

      assert violations == [],
             "Tool(s) create/destroy a workspace without going through " <>
               "Loopyard.Harness.Approvals.request (the human-approval guardrail): " <>
               "#{inspect(violations)}. Route the action through a propose_* approval."
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
        Path.wildcard("lib/loopyard_web/**/*.ex")
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

    test "every service_statuses assignment in workspace_live is guarded against empty replacement" do
      # The sidebar flapping bug was caused by unguarded assignments that
      # replaced a non-empty service list with []. Every assignment except
      # mount (first render) must go through guard_service_statuses/2.
      content = File.read!("lib/loopyard_web/live/workspace_live.ex")

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

      # Walk backwards from the assignment line to find the enclosing
      # `def`/`defp` header — that's the real "function name" we care
      # about. The old 12-line-context heuristic missed mount_with_workspace
      # when its body grew past 12 lines.
      enclosing_function_name = fn assign_line_num ->
        Enum.reduce_while(Enum.reverse(0..(assign_line_num - 1)), nil, fn i, _ ->
          l = Enum.at(lines, i) || ""

          case Regex.run(~r/^\s*(?:def|defp)\s+([a-z_][a-z0-9_?!]*)/i, l) do
            [_, name] -> {:halt, name}
            _ -> {:cont, nil}
          end
        end)
      end

      unguarded =
        Enum.filter(assignments, fn {line, n} ->
          # An assignment is "safe" if ANY of:
          #   - it's on a line that calls `force_assign_service_statuses/2`
          #     (explicit intentional-empty bypass, e.g. :workspace_stopped)
          #   - it's INSIDE `force_assign_service_statuses` itself
          #     (the helper body's one `assign/3` call)
          #   - its 12-line-preceding context calls
          #     `guard_service_statuses/2` (default protection)
          #   - its enclosing function is `mount_with_workspace` (initial
          #     mount, legitimate fresh value) or `force_assign_service_statuses`
          context = Enum.slice(lines, max(0, n - 11), 12) |> Enum.join("\n")
          enclosing = enclosing_function_name.(n)

          cond do
            String.contains?(line, "force_assign_service_statuses") -> false
            enclosing in ["force_assign_service_statuses", "mount_with_workspace"] -> false
            String.contains?(context, "guard_service_statuses") -> false
            true -> true
          end
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
        # Exclude tool files that construct URL route paths (not virtual dirs)
        |> Enum.reject(&String.contains?(&1, "tools/container/"))
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
  # Module size ratchet
  # ---------------------------------------------------------------
  # Catches files that are growing out of control. The threshold is
  # set to the current largest file + headroom. When a file exceeds
  # the cap, the test tells you to split it — not raise the cap.
  #
  # Known large files get an explicit allowance. Everything else
  # must stay under @default_max_lines.

  @default_max_lines 800
  @size_allowlist %{
    # These are known-large and have active split plans.
    # When you split one, lower its allowance or remove it.
    "lib/loopyard/chat_agent.ex" => 1700,
    "lib/loopyard_web/live/workspace_live.ex" => 1760,
    "lib/loopyard/eval_runner.ex" => 1200,
    "lib/loopyard_web/live/project_live.ex" => 850
  }

  describe "module size invariants" do
    test "no source file exceeds its line cap" do
      violations =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          lines = path |> File.stream!() |> Enum.count()
          cap = Map.get(@size_allowlist, path, @default_max_lines)

          if lines > cap do
            ["#{path} is #{lines} lines (cap: #{cap}) — split it"]
          else
            []
          end
        end)

      assert violations == [],
             "Files exceeding size cap:\n#{Enum.join(violations, "\n")}\n\n" <>
               "Don't raise the cap. Extract a module instead."
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp tool_modules do
    Loopyard.Tools.Container.__tool_server__().tools
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
