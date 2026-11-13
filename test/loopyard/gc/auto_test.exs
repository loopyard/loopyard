defmodule Loopyard.GC.AutoTest do
  @moduledoc """
  The automatic cleanup removes a candidate only when an EARLIER look already
  saw it (the age check, made of two looks), records what went, and survives
  a failing listing.
  """
  use ExUnit.Case, async: false

  alias Loopyard.GC.Auto

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{candidates: [], removed: []} end)

    Application.put_env(:loopyard, :gc_auto_survey_fun, fn ->
      {:ok, Agent.get(agent, & &1.candidates)}
    end)

    Application.put_env(:loopyard, :gc_auto_remove_fun, fn ripe ->
      Agent.update(agent, &%{&1 | removed: &1.removed ++ ripe})
      %{removed: ripe, failed: []}
    end)

    Application.put_env(:loopyard, :gc_auto_min_age_ms, 0)

    on_exit(fn ->
      for k <- [:gc_auto_survey_fun, :gc_auto_remove_fun, :gc_auto_min_age_ms],
          do: Application.delete_env(:loopyard, k)

      # Leave the singleton with nothing remembered for the next module.
      Application.put_env(:loopyard, :gc_auto_survey_fun, fn -> {:ok, []} end)
      Auto.sweep_now()
      Auto.sync()
      Application.delete_env(:loopyard, :gc_auto_survey_fun)
    end)

    # Start from nothing remembered.
    sweep()
    Agent.update(agent, &%{&1 | removed: []})
    {:ok, agent: agent}
  end

  defp sweep do
    Auto.sweep_now()
    Auto.sync()
  end

  defp candidates(agent, list), do: Agent.update(agent, &%{&1 | candidates: list})
  defp removed(agent), do: Agent.get(agent, & &1.removed)
  defp vol(name, size \\ 100), do: %{kind: :volume, name: name, size: size}

  test "the first look removes nothing; the second removes what the first saw", %{agent: agent} do
    candidates(agent, [vol("loopyard-test-a-code")])

    sweep()
    assert removed(agent) == []
    assert Auto.status().watching == 1

    sweep()
    assert removed(agent) == [vol("loopyard-test-a-code")]
    assert %{last: %{removed: 1, freed_bytes: 100, failed: 0}, watching: 0} = Auto.status()
  end

  test "a candidate that appeared since the last look waits its turn", %{agent: agent} do
    candidates(agent, [vol("loopyard-test-old-code")])
    sweep()

    candidates(agent, [vol("loopyard-test-old-code"), vol("loopyard-test-new-code")])
    sweep()

    # The one a test run may have just created is left for the next look.
    assert removed(agent) == [vol("loopyard-test-old-code")]
    assert Auto.status().watching == 1
  end

  test "younger than the minimum age is not removed even on a second look", %{agent: agent} do
    Application.put_env(:loopyard, :gc_auto_min_age_ms, 60_000)
    candidates(agent, [vol("loopyard-test-a-code")])

    sweep()
    sweep()

    assert removed(agent) == []
  end

  test "something that stopped being a candidate is forgotten, not removed later", %{agent: agent} do
    candidates(agent, [vol("loopyard-test-a-code")])
    sweep()

    # It came into use (no longer dangling), then dangles again much later:
    # that is a new sighting, not a ripe one.
    candidates(agent, [])
    sweep()
    candidates(agent, [vol("loopyard-test-a-code")])
    sweep()

    assert removed(agent) == []
  end

  test "a failing listing changes nothing and does not take the process down", %{agent: agent} do
    candidates(agent, [vol("loopyard-test-a-code")])
    sweep()

    pid = Process.whereis(Auto)
    Application.put_env(:loopyard, :gc_auto_survey_fun, fn -> raise "docker exploded" end)
    sweep()
    Application.put_env(:loopyard, :gc_auto_survey_fun, fn -> {:error, "refusing"} end)
    sweep()

    assert Process.whereis(Auto) == pid
    assert removed(agent) == []
    # What it had seen is still remembered for the next good look.
    assert Auto.status().watching == 1
  end

  test "a skipped look (daemon down) changes nothing" do
    Application.put_env(:loopyard, :gc_auto_survey_fun, fn -> :skipped end)
    sweep()
    assert Auto.status().watching == 0
  end
end
