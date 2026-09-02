defmodule Loopyard.AgentCase do
  @moduledoc """
  The test template for modules that boot `ChatAgent`s (via
  `Loopyard.TestHelpers.start_agent/1`).

  Every module gets ONE isolated workspace (a temp dir → its own workspace
  group), created in `setup_all` and torn down when the module finishes. Each
  test's `start_agent/1` lands in it automatically — the template seeds the
  process-dictionary key the helper memoises on — so a module's tests share
  a group (cheap: one boot per module, not per test) while NO module shares
  the checkout's workspace group with another. That shared group was the
  flake factory: a neighbour test crashing or restarting it killed agents
  mid-test ("no process" from `:sys.get_state`).

      use Loopyard.AgentCase

  Pass `:working_dir` to `start_agent/1` only when a test needs a specific
  path of its own (it then gets per-test teardown as before).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Loopyard.AgentCase, only: [module_workspace: 0]
    end
  end

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "loopyard-test-mod-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    workspace_id = Loopyard.TestHelpers.ensure_workspace(path)

    on_exit(fn ->
      Loopyard.TestHelpers.destroy_workspace(workspace_id)
      File.rm_rf(path)
    end)

    %{module_workspace: path, module_workspace_id: workspace_id}
  end

  setup %{module_workspace: path, module_workspace_id: workspace_id} do
    # Seed the helper's per-process memo so start_agent/1 reuses the module's
    # workspace, and mark it module-owned so the helper doesn't register a
    # per-test teardown for it.
    Process.put(:loopyard_test_workspace_path, path)
    Process.put(:loopyard_test_module_workspace_id, workspace_id)
    :ok
  end

  @doc "The module's shared workspace dir (the same path `start_agent/1` uses)."
  def module_workspace, do: Process.get(:loopyard_test_workspace_path)
end
