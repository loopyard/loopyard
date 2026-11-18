defmodule Loopyard.Harness.ModelsTest do
  @moduledoc """
  The pickers offer what the harness's own session lists, so a newer adapter
  brings its newer models without an edit here.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Harness.{Catalog, Models}

  # What claude-agent-acp 0.108.0 reported on the v6 image (2026-11-17),
  # through Connection.available_models/1.
  @live [
    %{id: "default", name: "Default (recommended)", description: "Sonnet", label: "Default"},
    %{
      id: "sonnet",
      name: "Sonnet 5.5",
      description: "Sonnet 5.5 · Efficient",
      label: "Sonnet 5.5"
    },
    %{
      id: "fable",
      name: "Fable 5.2",
      description: "Fable 5.2 · Most capable",
      label: "Fable 5.2"
    },
    %{id: "opus", name: "Opus 5.5", description: "Opus 5.5 · Best", label: "Opus 5.5"},
    %{id: "haiku", name: "Haiku 5.5", description: "Haiku 5.5 · Fastest", label: "Haiku 5.5"}
  ]

  setup do
    Models.reset()
    on_exit(&Models.reset/0)
  end

  test "before any session has reported, the Catalog's alias seed is offered" do
    assert Models.list(:claude) == Catalog.fetch(:claude).models
    assert {"claude:opus", "Opus"} in Catalog.model_options(:claude)
    assert Models.list(:codex) == []
  end

  test "a session's list replaces the seed, labels and order included" do
    :ok = Models.record(:claude, @live)

    assert Models.list(:claude) == [
             {"sonnet", "Sonnet 5.5"},
             {"fable", "Fable 5.2"},
             {"opus", "Opus 5.5"},
             {"haiku", "Haiku 5.5"}
           ]

    # The adapter's own "default" entry is ours to add, once.
    assert Catalog.model_options(:claude) |> Enum.map(&elem(&1, 0)) ==
             ~w(claude:sonnet claude:fable claude:opus claude:haiku claude:default)

    assert {"opus", "Opus 5.5"} in Catalog.subagent_model_options(:claude)
    assert Catalog.subagent_model_valid?(:claude, "fable")
    refute Catalog.subagent_model_valid?(:claude, "claude-opus-5")
  end

  test "a release the adapter starts listing shows up with no code change" do
    Models.record(:claude, @live ++ [%{id: "saga", name: "Saga 1", label: "Saga 1"}])
    assert {"claude:saga", "Saga 1"} in Catalog.model_options(:claude)
  end

  test "a harness with no seed gets a picker once a session reports" do
    Models.record(:codex, [%{id: "gpt-5.6", name: "GPT-5.6", label: "GPT-5.6"}])
    assert {"codex:gpt-5.6", "GPT-5.6"} in Catalog.model_options(:codex)
    # One harness's list never leaks into another's.
    assert Models.list(:claude) == Catalog.fetch(:claude).models
  end

  test "an empty or malformed report keeps what was known" do
    Models.record(:claude, @live)
    Models.record(:claude, [])
    Models.record(:claude, [%{id: "default", label: "Default"}])
    Models.record(:claude, :nonsense)
    assert length(Models.list(:claude)) == 4
  end

  describe "float/2: a stored pin from an older release" do
    test "an id moves to its family's alias" do
      assert Models.float(:claude, "claude-opus-5") == "opus"
      assert Models.float(:claude, "claude-opus-4-8") == "opus"
      assert Models.float(:claude, "claude-sonnet-5") == "sonnet"
      assert Models.float(:claude, "claude-fable-5-1") == "fable"
      assert Models.float(:claude, "claude-haiku-4-5-20251001") == "haiku"
    end

    test "so does the display name a saved row carries" do
      assert Models.float(:claude, "Opus 4.8") == "opus"
      assert Models.float(:claude, "Sonnet 5") == "sonnet"
      Models.record(:claude, @live)
      assert Models.float(:claude, "Opus 5.5") == "opus"
    end

    test "a value the harness offers is kept; anything else is nil" do
      assert Models.float(:claude, "opus") == "opus"
      assert Models.float(:claude, "Newer version available") == nil
      assert Models.float(:claude, "claude-mythos-5-2") == nil
      assert Models.float(:claude, nil) == nil
      # Codex has no family pattern: only an exact, listed id survives.
      assert Models.float(:codex, "claude-opus-5") == nil
      Models.record(:codex, [%{id: "gpt-5.6", label: "GPT-5.6"}])
      assert Models.float(:codex, "gpt-5.6") == "gpt-5.6"
    end
  end

  describe "capture/1" do
    defmodule Backend do
      def available_models(:live), do: [%{id: "opus", label: "Opus 9"}]
      def available_models(:down), do: exit(:noproc)
    end

    # The agent's state is a STRUCT: `state[:session_opts]` raises on one, and
    # a rescue around it once made this function a silent no-op in production.
    defmodule State do
      defstruct [:session, :backend, :model, session_opts: []]
    end

    test "records the live session's list and names the agent's model from it" do
      state = %State{
        session: :live,
        backend: Backend,
        model: "claude-opus-5",
        session_opts: [harness: :claude, model: "opus"]
      }

      assert %State{model: "Opus 9"} = Models.capture(state)
      assert Models.list(:claude) == [{"opus", "Opus 9"}]
    end

    test "a model the session does not list keeps its name" do
      state = %State{session: :live, backend: Backend, model: "Custom", session_opts: []}
      assert Models.capture(state) == state
    end

    test "never raises: a dead session, no session, a backend without a list" do
      down = %State{session: :down, backend: Backend, session_opts: [harness: :claude]}
      assert Models.capture(down) == down

      none = %State{session: nil, backend: Backend}
      assert Models.capture(none) == none

      fake = %State{session: :live, backend: Loopyard.Harness.Fake}
      assert Models.capture(fake) == fake
      assert Models.list(:claude) == Catalog.fetch(:claude).models
    end
  end
end
