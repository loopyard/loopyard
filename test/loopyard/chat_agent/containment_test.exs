defmodule Loopyard.ChatAgent.ContainmentTest do
  @moduledoc """
  The harness-runtime containment invariant (docs/SECURITY.md): no agent may
  start with a backend/opts that would run its harness process on the host.
  Enforced in `Initializer.assert_runtime_contained!`.
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:loopyard, :crash_backoff_base_ms) end)
    :ok
  end

  defp alive?(id), do: match?([{_pid, _}], Registry.lookup(Loopyard.ChatAgentRegistry, id))

  defp try_start(opts) do
    Loopyard.TestHelpers.start_agent(opts)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  test "an ACP agent with no :container refuses to start (would run on the host)" do
    id = "containment-acp-nohost-#{:rand.uniform(1_000_000)}"

    # ACP with no workspace_id and no explicit :container → the harness would
    # launch on the HOST. The containment gate must refuse it. (There is no
    # host-execution backend anymore — Harness.Claude was deleted — so this
    # ACP-without-container path is the only remaining way to reach the host.)
    try_start(
      id: id,
      name: "c",
      working_dir: File.cwd!(),
      started_by: "test",
      backend: Loopyard.Harness.ACP
    )

    Process.sleep(50)
    on_exit(fn -> ChatAgent.stop_agent(id) end)

    refute alive?(id), "an ACP agent without a container must be refused (it runs on the host)"
  end

  test "a Fake/neutral backend (no host runtime) is allowed" do
    id = "containment-fake-#{:rand.uniform(1_000_000)}"

    try_start(
      id: id,
      name: "f",
      working_dir: File.cwd!(),
      started_by: "test",
      backend: Loopyard.Harness.Fake
    )

    Process.sleep(50)
    on_exit(fn -> ChatAgent.stop_agent(id) end)

    assert alive?(id), "the Fake backend spawns no host runtime and must be allowed"
  end
end
