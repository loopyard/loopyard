defmodule Loopyard.Fleet.WatchTest do
  @moduledoc """
  The fleet watch (#119) against real ETS rows and the real inbox store: each
  condition raises ONE item and settles when it clears; the chief of staff is
  woken with ONE batched, stamped message, rate-limited, never re-announcing,
  and never when it can't act.
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent.Thread
  alias Loopyard.{AccountLimits, Notifications, Workstation}
  alias Loopyard.Docker.Disk
  alias Loopyard.Fleet.{Conditions, Watch}
  alias Loopyard.Notifications.Item
  require Item

  @env [
    :fleet_watch_grace_ms,
    :fleet_watch_offline_grace_ms,
    :fleet_watch_wake_interval_ms,
    :fleet_watch_wakes_chief?,
    :fleet_watch_deliver_fun
  ]

  setup do
    ident = "fw-#{System.unique_integer([:positive])}"
    :ok = Workstation.create(ident)
    sys = "fw-sys-#{System.unique_integer([:positive])}"
    File.write!(Loopyard.Agents.marker_path(ident), Jason.encode!(%{default_agent_id: sys}))
    put_row(%{id: sys, name: "Operator", scope: :system, workstation_identity: ident})

    me = self()
    Application.put_env(:loopyard, :fleet_watch_grace_ms, 0)
    Application.put_env(:loopyard, :fleet_watch_offline_grace_ms, 0)
    Application.put_env(:loopyard, :fleet_watch_wake_interval_ms, 60_000)
    Application.put_env(:loopyard, :fleet_watch_wakes_chief?, true)
    Application.put_env(:loopyard, :fleet_watch_deliver_fun, &send(me, {:wake, &1, &2}))

    on_exit(fn ->
      Enum.each(@env, &Application.delete_env(:loopyard, &1))

      for {id, %{workstation_identity: ^ident}} <- :ets.tab2list(:chat_agents) do
        :ets.delete(:chat_agents, id)
      end

      for {id, %Item{agent_id: aid}} <- :ets.tab2list(:notifications),
          String.starts_with?(aid, "fw-") do
        :ets.delete(:notifications, id)
      end

      AccountLimits.clear_all()
      File.rm_rf(Workstation.dir(ident))
    end)

    %{ident: ident, sys: sys}
  end

  defp put_row(row) do
    row = Map.merge(%{status: :idle, name: "Worker", messages: [], workspace_id: nil}, row)
    :ets.insert(:chat_agents, {row.id, row})
    row.id
  end

  defp worker(ident, fields) do
    id = "fw-#{System.unique_integer([:positive])}"
    put_row(Map.merge(%{id: id, workspace_id: "ws-fw", workstation_identity: ident}, fields))
  end

  defp sweep(ids) do
    :ok = Watch.sweep_now(only: ids)
    :ok = Watch.sync()
    Notifications.sync()
  end

  defp item(id, c), do: Notifications.get(Conditions.item_id(id, c))

  defp wakes do
    receive do
      {:wake, sys, text} -> [{sys, text} | wakes()]
    after
      50 -> []
    end
  end

  describe "the inbox" do
    test "each condition raises one item and settles when it clears", %{ident: ident, sys: sys} do
      conditions = [
        interrupted: %{interrupted?: true},
        signed_out: %{status: :auth_expired},
        quarantined: %{quarantined: true},
        failed_turn: %{failed_prompt: "build it"},
        offline: %{status: :crashed}
      ]

      for {c, fields} <- conditions do
        id = worker(ident, fields)
        sweep([id, sys])

        assert %Item{kind: :stuck, status: :open, meta: meta} = item(id, c)
        assert meta.condition == c
        assert Enum.count(Notifications.open([:stuck]), &(&1.agent_id == id)) == 1

        # Still in it: nothing new.
        sweep([id, sys])
        assert Enum.count(Notifications.all(), &(&1.agent_id == id)) == 1

        put_row(%{id: id, workspace_id: "ws-fw", workstation_identity: ident})
        sweep([id, sys])
        assert %Item{status: :settled, outcome: :cleared} = item(id, c)
      end
    end

    test "a condition inside its grace raises nothing", %{ident: ident, sys: sys} do
      Application.put_env(:loopyard, :fleet_watch_offline_grace_ms, 60_000)
      id = worker(ident, %{status: :backoff})
      sweep([id, sys])
      assert item(id, :offline) == nil
    end

    test "the stuck kind waits on a human" do
      assert :stuck in Item.needs_human_kinds()
      assert Item.item_only?(:stuck)
    end
  end

  describe "waking the chief of staff" do
    test "one batched, stamped message names each agent, and nothing is re-announced",
         %{ident: ident, sys: sys} do
      a = worker(ident, %{name: "Builder", interrupted?: true})
      b = worker(ident, %{name: "Docs", status: :auth_expired})
      sweep([a, b, sys])

      assert [{^sys, text}] = wakes()
      assert Thread.sender(text) == Thread.system_sender()
      assert text =~ "2 agents need attention"
      assert text =~ "Builder [#{a}]"
      assert text =~ "Docs [#{b}]"

      # Same conditions on the next sweep: no news, no wake.
      sweep([a, b, sys])
      assert wakes() == []
    end

    test "a quiet fleet wakes nobody", %{ident: ident, sys: sys} do
      id = worker(ident, %{})
      sweep([id, sys])
      assert wakes() == []
    end

    test "rate-limited: news inside the interval waits for it, then goes as one",
         %{ident: ident, sys: sys} do
      a = worker(ident, %{interrupted?: true})
      sweep([a, sys])
      assert [{^sys, _}] = wakes()

      b = worker(ident, %{status: :crashed})
      c = worker(ident, %{quarantined: true})
      sweep([a, b, c, sys])
      assert wakes() == []

      Application.put_env(:loopyard, :fleet_watch_wake_interval_ms, 0)
      sweep([a, b, c, sys])
      assert [{^sys, text}] = wakes()
      assert text =~ "2 agents need attention"
      assert text =~ b and text =~ c
      refute text =~ a
    end

    test "an open plan-limit item is announced too", %{ident: ident, sys: sys} do
      id = worker(ident, %{name: "Limited", status: :rate_limited})
      Notifications.raise_item(Item.plan_limit(id, "at its limit", %{account: ident}))
      Notifications.sync()
      sweep([id, sys])

      assert [{^sys, text}] = wakes()
      assert text =~ "Limited [#{id}] (account #{ident}): at plan limit"
    end

    test "a condition that clears and comes back is news again", %{ident: ident, sys: sys} do
      Application.put_env(:loopyard, :fleet_watch_wake_interval_ms, 0)
      id = worker(ident, %{status: :auth_expired})
      sweep([id, sys])
      assert [_] = wakes()

      put_row(%{id: id, workspace_id: "ws-fw", workstation_identity: ident})
      sweep([id, sys])

      put_row(%{
        id: id,
        workspace_id: "ws-fw",
        workstation_identity: ident,
        status: :auth_expired
      })

      sweep([id, sys])
      assert [_] = wakes()
    end
  end

  describe "never when the chief of staff can't act" do
    test "it is the one in trouble", %{ident: ident, sys: sys} do
      put_row(%{id: sys, scope: :system, workstation_identity: ident, status: :auth_expired})
      id = worker(ident, %{interrupted?: true})
      sweep([id, sys])

      assert wakes() == []
      # Its own trouble is still an inbox item for the human.
      assert %Item{status: :open} = item(sys, :signed_out)
    end

    test "its own account is at a plan limit", %{ident: ident, sys: sys} do
      AccountLimits.mark(ident, :claude, System.system_time(:millisecond) + 60_000)
      id = worker(ident, %{interrupted?: true})
      sweep([id, sys])
      assert wakes() == []

      # The limit lifts: the held news goes out.
      AccountLimits.clear(ident, :claude)
      sweep([id, sys])
      assert [{^sys, _}] = wakes()
    end

    test "the Docker disk is full", %{ident: ident, sys: sys} do
      Notifications.upsert(Disk.alert_item(:down, {:down, "0 B free"}))
      Notifications.sync()
      on_exit(fn -> :ets.delete(:notifications, Disk.alert_id()) end)

      id = worker(ident, %{interrupted?: true})
      sweep([id, sys])
      assert wakes() == []
    end

    test "the off switch", %{ident: ident, sys: sys} do
      Application.put_env(:loopyard, :fleet_watch_wakes_chief?, false)
      id = worker(ident, %{interrupted?: true})
      sweep([id, sys])

      assert wakes() == []
      assert %Item{status: :open} = item(id, :interrupted)
    end
  end
end
