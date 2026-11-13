defmodule Loopyard.Fleet.ConditionsTest do
  @moduledoc "The fleet watch's pure half (#119): what is wrong, for how long, and who to wake."
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.Thread
  alias Loopyard.Fleet.Conditions

  describe "of/1 — one condition per agent, the most decisive" do
    test "each condition, from the summary fields that carry it" do
      assert Conditions.of(%{status: :idle, quarantined: true, auth_error: "401"}) == :quarantined
      assert Conditions.of(%{status: :auth_expired}) == :signed_out
      # The self-heal retry flips the status back to idle; the error persists.
      assert Conditions.of(%{status: :idle, auth_error: "401"}) == :signed_out
      assert Conditions.of(%{status: :crashed}) == :offline
      assert Conditions.of(%{status: :backoff}) == :offline
      assert Conditions.of(%{status: :idle, failed_prompt: "do it"}) == :failed_turn
      assert Conditions.of(%{status: :idle, interrupted?: true}) == :interrupted
    end

    test "a healthy, busy or deliberately stopped agent is in none" do
      assert Conditions.of(%{status: :idle}) == nil
      assert Conditions.of(%{status: :thinking, interrupted?: true}) == nil
      assert Conditions.of(%{status: :rate_limited}) == nil
      assert Conditions.of(%{status: :stopped, quarantined: true}) == nil
      assert Conditions.of(nil) == nil
    end
  end

  describe "observe/4 + changes/2" do
    @opts %{grace_ms: 100, offline_grace_ms: 1_000}

    test "a condition is confirmed only once it has held for its grace" do
      {seen, confirmed} = Conditions.observe(%{}, %{"a" => :signed_out}, 0, @opts)
      assert confirmed == %{}
      {seen, confirmed} = Conditions.observe(seen, %{"a" => :signed_out}, 150, @opts)
      assert confirmed == %{"a" => :signed_out}

      # Offline waits longer: a backoff usually heals by itself.
      {seen, confirmed} = Conditions.observe(seen, %{"b" => :offline}, 200, @opts)
      assert confirmed == %{}
      assert Map.keys(seen) == [{"b", :offline}]
      {_seen, confirmed} = Conditions.observe(seen, %{"b" => :offline}, 1_300, @opts)
      assert confirmed == %{"b" => :offline}
    end

    test "a condition that clears and comes back starts its grace over" do
      {seen, _} = Conditions.observe(%{}, %{"a" => :signed_out}, 0, @opts)
      {seen, _} = Conditions.observe(seen, %{}, 50, @opts)
      {_seen, confirmed} = Conditions.observe(seen, %{"a" => :signed_out}, 120, @opts)
      assert confirmed == %{}
    end

    test "raise new and changed conditions, settle cleared and replaced ones" do
      raised = %{"a" => :signed_out, "b" => :offline, "c" => :interrupted}
      confirmed = %{"a" => :signed_out, "b" => :quarantined, "d" => :failed_turn}

      assert Conditions.changes(raised, confirmed) ==
               {[{"b", :quarantined}, {"d", :failed_turn}],
                [{"b", :offline}, {"c", :interrupted}]}

      assert Conditions.changes(raised, raised) == {[], []}
    end
  end

  describe "words" do
    test "every condition has a word, a decisive label and one action" do
      for c <- Conditions.all() do
        assert is_binary(Conditions.word(c))
        label = Conditions.label(c, "Builder", "brad")
        assert label =~ "Builder"
        assert {kind, words} = Conditions.action(c, "brad")
        assert kind in [:continue, :account, :chat]
        assert is_binary(words)
        assert Conditions.may_do(c, "id1") |> is_binary()
      end

      assert Conditions.action(:interrupted, nil) |> elem(0) == :continue

      assert Conditions.action(:signed_out, "brad") ==
               {:account, "Open brad and sign it in again."}
    end
  end

  describe "the wake" do
    @ok %{
      enabled?: true,
      system: %{id: "op", status: :idle},
      system_condition: nil,
      system_limited?: false,
      disk_down?: false
    }

    test "only when the chief of staff can act" do
      assert Conditions.can_wake(@ok) == :ok
      assert Conditions.can_wake(%{@ok | enabled?: false}) == {:no, :off}
      assert Conditions.can_wake(%{@ok | system: nil}) == {:no, :no_chief}
      assert Conditions.can_wake(%{@ok | disk_down?: true}) == {:no, :disk_down}
      assert Conditions.can_wake(%{@ok | system_condition: :signed_out}) == {:no, :chief_stuck}
      assert Conditions.can_wake(%{@ok | system_limited?: true}) == {:no, :chief_limited}

      assert Conditions.can_wake(%{@ok | system: %{status: :rate_limited}}) ==
               {:no, :chief_limited}
    end

    test "one stamped message naming each agent by id, its condition and what to do" do
      text =
        Conditions.wake_text([
          %{id: "a1", name: "Builder", condition: :interrupted, account: "brad"},
          %{id: "b2", name: "Docs", condition: :plan_limit, account: "brad"}
        ])

      assert Thread.sender(text) == Thread.system_sender()
      assert text =~ "2 agents need attention"
      assert text =~ "Builder [a1] (account brad): interrupted"
      assert text =~ "agent action=continue target=a1"
      assert text =~ "Docs [b2] (account brad): at plan limit"
      assert text =~ "answering a decision stay the human's"
    end
  end
end
