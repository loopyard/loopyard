defmodule BoomLooperWeb.LiveViewAsyncContractTest do
  @moduledoc """
  AST-level scan that fails the build if any LiveView's `mount/3` or
  `handle_params/3` body contains a synchronous slow call.

  This test exists because we shipped this exact bug TWICE:
  - chat_live `:index` handle_params calling `VolumeManager.read_file`
  - project_live mount calling `ServiceStatus.for_workspace` in a loop

  Both regressions made the page take seconds to paint. The unit-level
  `:timer.tc` mount tests catch the symptom; this test catches the cause
  by name. If you add a new slow function call to mount, this test
  fails immediately with a clear pointer to the offender.

  How to fix a failure:
  1. Move the slow call into a `start_async/3` or `send(self(), ...)`
  2. Render a placeholder (`AsyncResult.loading()` / empty assign) until
     the async result lands

  How to add a new forbidden call:
  - Put the `{module_leaf_atom, function_atom}` pair in @forbidden_calls
  - Or `{module_leaf_atom, :_}` to forbid the entire module
  """
  use ExUnit.Case, async: true

  # Module-leaf + function-atom pairs that must NEVER be called in
  # mount or handle_params. Match the LAST segment of the alias only —
  # `BoomLooper.Docker.foo` and `Docker.foo` (aliased) both match the
  # `:Docker` leaf. Use `:_` to forbid every function in the module.
  @forbidden_calls [
    # Docker shells out to the docker CLI for every function — slow.
    {:Docker, :_},

    # Volume operations spawn temporary containers. Read/write/list/info
    # all involve docker exec or docker run.
    {:VolumeManager, :read_file},
    {:VolumeManager, :write_file},
    {:VolumeManager, :list_workspace_volumes},
    {:VolumeManager, :list_all_volumes},
    {:VolumeManager, :volume_info},
    {:VolumeManager, :volume_ls},
    {:VolumeManager, :copy_to_volume},
    {:VolumeManager, :glob},
    {:VolumeManager, :clone_into_volume},
    {:VolumeManager, :clone_in_container},
    {:VolumeManager, :pull_in_container},
    {:VolumeManager, :prune_orphaned_volumes},
    {:VolumeManager, :delete_volume},
    {:VolumeManager, :create_volume},
    {:VolumeManager, :volume_exists?},
    {:VolumeManager, :volume_has_code?},

    # ServiceStatus.for_workspace fans out into N Docker calls.
    {:ServiceStatus, :for_workspace},

    # Workspace.load_from_volume / save_to_volume go through VolumeManager.
    {:Workspace, :load_from_volume},
    {:Workspace, :save_to_volume},
    {:Workspace, :load},
    {:Workspace, :save},

    # All Compose functions invoke docker compose.
    {:Compose, :_},

    # Slow SystemStats slices — these MUST be called from start_async,
    # never inline. The fast ones (beam_stats, workspace_stats) are
    # explicitly NOT in this list.
    {:SystemStats, :host_cpu},
    {:SystemStats, :host_memory},
    {:SystemStats, :host_disk},
    {:SystemStats, :host_uptime},
    {:SystemStats, :docker_container_stats},
    {:SystemStats, :claude_cli_processes},
    {:SystemStats, :agent_stats},
    {:SystemStats, :service_stats},

    # Container tools all shell out into docker exec.
    {:Container, :_}
  ]

  @callback_names [:mount, :handle_params]

  describe "the scanner itself" do
    # These tests prove the scanner catches violations. Without them,
    # the main test could pass not because the codebase is clean but
    # because the scanner is broken — silent green is the worst kind.

    test "catches a forbidden call inside def mount" do
      offending = """
      defmodule FakeLive do
        def mount(_params, _session, socket) do
          BoomLooper.Docker.container_running?("foo")
          {:ok, socket}
        end
      end
      """

      assert [{_path, :mount, :Docker, :container_running?, _line} | _] =
               scan_string(offending)
    end

    test "catches an aliased forbidden call" do
      offending = """
      defmodule FakeLive do
        alias BoomLooper.VolumeManager
        def handle_params(_p, _u, socket) do
          VolumeManager.read_file("vol", "/path")
          {:noreply, socket}
        end
      end
      """

      assert [{_path, :handle_params, :VolumeManager, :read_file, _line} | _] =
               scan_string(offending)
    end

    test "ignores fast calls" do
      clean = """
      defmodule FakeLive do
        def mount(_params, _session, socket) do
          BoomLooper.SystemStats.beam_stats()
          BoomLooper.SystemStats.workspace_stats()
          {:ok, socket}
        end
      end
      """

      assert scan_string(clean) == []
    end

    test "ignores function captures passed to start_async (they're deferred, not sync)" do
      clean = """
      defmodule FakeLive do
        def mount(_p, _s, socket) do
          start_async(socket, :stats, &BoomLooper.SystemStats.docker_container_stats/0)
          {:ok, socket}
        end
      end
      """

      assert scan_string(clean) == []
    end

    test "ignores slow calls in non-callback functions" do
      # The scanner ONLY looks at mount/handle_params. Helpers can call
      # whatever they want — they're invoked from handle_async/handle_info.
      clean = """
      defmodule FakeLive do
        def mount(_p, _s, socket), do: {:ok, socket}

        defp helper(socket) do
          BoomLooper.Docker.container_running?("foo")
          socket
        end
      end
      """

      assert scan_string(clean) == []
    end

    defp scan_string(source) do
      {:ok, ast} = Code.string_to_quoted(source)

      callback_bodies(ast)
      |> Enum.flat_map(fn {callback, body} ->
        body
        |> collect_remote_calls()
        |> Enum.filter(&forbidden?/1)
        |> Enum.map(fn {mod, fun, line} -> {"<test>", callback, mod, fun, line} end)
      end)
    end
  end

  test "no LiveView mount or handle_params calls a forbidden slow function" do
    offenders =
      live_view_files()
      |> Enum.flat_map(&scan_file/1)

    if offenders != [] do
      formatted =
        offenders
        |> Enum.map_join("\n", fn {file, callback, mod, fun, line} ->
          "  #{file}:#{line}  in def #{callback}/_  → #{mod}.#{fun}"
        end)

      flunk("""
      Found synchronous slow calls inside LiveView mount/handle_params.
      These will block the page from painting. Move them into a
      `start_async/3` (preferred) or `send(self(), :fetch_xxx)` and
      populate the assign from `handle_async/3` / `handle_info/2`.

      #{formatted}

      See CLAUDE.md → "Mount must render instantly".
      """)
    end
  end

  defp live_view_files do
    Path.wildcard("lib/boom_looper_web/live/*.ex")
  end

  defp scan_file(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    callback_bodies(ast)
    |> Enum.flat_map(fn {callback, body} ->
      body
      |> collect_remote_calls()
      |> Enum.filter(&forbidden?/1)
      |> Enum.map(fn {mod, fun, line} -> {path, callback, mod, fun, line} end)
    end)
  end

  # Walk top-level module body for `def mount(...)` and `def handle_params(...)`
  # clauses. Returns a list of `{callback_name, body_ast}`.
  defp callback_bodies({:defmodule, _, [_, [do: {:__block__, _, top}]]}), do: extract_callbacks(top)
  defp callback_bodies({:defmodule, _, [_, [do: single]]}), do: extract_callbacks([single])
  defp callback_bodies(_), do: []

  defp extract_callbacks(top_level) do
    top_level
    |> Enum.flat_map(&extract_from_node/1)
  end

  # `def mount(args, ...) do body end`
  defp extract_from_node({:def, _, [{name, _, _args}, [do: body]]}) when name in @callback_names do
    [{name, body}]
  end

  # `def mount(args, ...), do: body` (one-liner)
  defp extract_from_node({:def, _, [{name, _, _}, body]}) when name in @callback_names and is_list(body) do
    case body do
      [do: body_ast] -> [{name, body_ast}]
      _ -> []
    end
  end

  defp extract_from_node(_), do: []

  # Walk a body AST and return every `Module.function(args)` DIRECT call
  # as `{module_leaf_atom, function_atom, line}`.
  #
  # Skips function captures like `&Module.fun/0` — those are deferred
  # references passed to `start_async/3`, not synchronous invocations.
  # Without this distinction, `start_async(socket, :stats, &SystemStats.docker_container_stats/0)`
  # would be flagged even though it's the CORRECT async pattern.
  defp collect_remote_calls(body) do
    # Strip function captures before walking so their inner dot nodes
    # don't get collected. Macro.prewalk can't skip subtrees, so we
    # replace the whole &-node with a placeholder.
    stripped =
      Macro.prewalk(body, fn
        {:&, _, _} -> :__capture_removed__
        node -> node
      end)

    {_, calls} =
      Macro.prewalk(stripped, [], fn
        {{:., meta, [{:__aliases__, _, mod_path}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          leaf = mod_path |> List.last()
          line = Keyword.get(meta, :line, 0)
          {node, [{leaf, fun, line} | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp forbidden?({mod_leaf, fun, _line}) do
    Enum.any?(@forbidden_calls, fn
      {^mod_leaf, :_} -> true
      {^mod_leaf, ^fun} -> true
      _ -> false
    end)
  end
end
