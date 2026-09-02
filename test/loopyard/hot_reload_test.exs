defmodule Loopyard.HotReloadTest do
  use ExUnit.Case, async: true

  alias Loopyard.HotReload

  describe "reload/1 with an explicit module" do
    test "re-purges and re-loads the given module without error" do
      # `Loopyard.HotReload` itself is a safe, side-effect-free target
      # to reload inside tests — it has no GenServer, no ETS, no
      # supervised children to disturb.
      assert {:module, Loopyard.HotReload} = HotReload.reload(Loopyard.HotReload)
    end

    test "accepts a list of modules and returns per-module results" do
      results = HotReload.reload([Loopyard.HotReload, Loopyard.Workspace.Destructor])
      assert [{:module, _}, {:module, _}] = results
    end
  end

  describe "reload/0" do
    # IEx.Helpers.recompile/0 walks the whole Mix project. Under full
    # suite load + a fresh compile it can take well over a second.
    # Recompiles the whole project — seconds of CPU the default run doesn't
    # need to spend; reload/1 above covers the purge/load path every run.
    @tag :slow
    @tag timeout: 15_000
    test "returns a list (possibly empty) of reloaded modules" do
      # `reload/0` calls `IEx.Helpers.recompile/0`; in the test env
      # recompile returns :noop (nothing to compile), so the list of
      # stale-reloaded modules is usually empty. Either way the call
      # must not raise.
      result = HotReload.reload()
      assert is_list(result)
    end
  end
end
