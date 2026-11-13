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

    # Plan limits are per ACCOUNT and every test agent bills the same default
    # identity: a refusal one test provokes must not hold the next test's sends.
    Loopyard.AccountLimits.clear_all()
    ExUnit.Callbacks.on_exit(&Loopyard.AccountLimits.clear_all/0)
    # An agent test that hits a plan limit raises a "limit:<agent>" inbox item.
    # The store is shared by every test module, and a leftover one showed up on
    # other modules' decks (a deck test saw three plan-limit slides, not one).
    ExUnit.Callbacks.on_exit(&__MODULE__.clear_plan_limit_items/0)
    :ok
  end

  @doc "The module's shared workspace dir (the same path `start_agent/1` uses)."
  def module_workspace, do: Process.get(:loopyard_test_workspace_path)

  @doc "Drop every plan-limit item from the shared inbox store (see setup)."
  def clear_plan_limit_items do
    for {"limit:" <> _ = id, _} <- :ets.tab2list(:notifications),
        do: :ets.delete(:notifications, id)

    :ok
  rescue
    _ -> :ok
  end
end
