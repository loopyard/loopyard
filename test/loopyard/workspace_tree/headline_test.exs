defmodule Loopyard.WorkspaceTree.HeadlineTest do
  @moduledoc """
  The priority-ordered workspace headline is domain code (the operator queue
  derives its state from it); the Birdseye component only adds a colour class
  on top. Both must agree — so the wrapper is checked against the domain.
  """
  use ExUnit.Case, async: true

  alias Loopyard.WorkspaceTree.Headline
  alias LoopyardWeb.Components.Birdseye

  test "needs-you beats everything" do
    ws = %{needs_you: :question, broken: :auth_expired, agents: [%{status: :thinking}]}
    assert %{kind: :needs_you, text: "asked a question"} = Headline.headline(ws)
  end

  test "broken beats working" do
    ws = %{broken: :quarantined, agents: [%{status: :thinking}]}
    assert %{kind: :broken, text: "crash-looping"} = Headline.headline(ws)
  end

  test "a working agent reads as a calm verb from the tool KIND, never the raw name" do
    ws = %{agents: [%{status: :thinking, active_tool: "Bash"}]}
    assert %{kind: :working, text: "running…"} = Headline.headline(ws)

    ws = %{agents: [%{status: :thinking, active_tool: "mcp__loopyard-container__exec"}]}
    assert %{kind: :working, text: "running…"} = Headline.headline(ws)

    ws = %{agents: [%{status: :booting}]}
    assert %{kind: :working, text: "working…"} = Headline.headline(ws)
  end

  test "line changes carry the raw +/- split" do
    ws = %{agents: [%{status: :idle}], changes: %{added: 3, removed: 1}}
    assert %{kind: :changed, added: 3, removed: 1, text: "+3 −1"} = Headline.headline(ws)
  end

  test "quiet workspaces have no headline" do
    assert Headline.headline(%{agents: [%{status: :idle}]}) == nil
    assert Headline.headline(%{agents: [], changes: %{added: 0, removed: 0}}) == nil
    assert Headline.headline(%{}) == nil
  end

  test "the Birdseye component wraps the domain headline with a class only" do
    ws = %{needs_you: :approval, agents: []}

    assert %{kind: :needs_you, text: "wants approval", class: "text-orange-600" <> _} =
             Birdseye.headline(ws)

    assert Birdseye.headline(%{}) == nil
  end
end
