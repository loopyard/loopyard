defmodule LoopyardWeb.ComposerWritesTest do
  @moduledoc """
  The composer belongs to the human. Only a human asking for it may put text in.

  CLAUDE.md states it: "Recovery NEVER writes into the composer — the input box
  is for humans only (machine prompts/seeds must never be 'restored' there)."
  It got broken anyway, not by a recovery path but by a layout choice: the text
  of a QUEUED message was itself a full-width `phx-click="edit_pending"` button.

  `edit_pending` does two things — removes the message from the queue AND pushes
  its text into the composer. So a tap on what looks like plain text (which, on
  a phone, is how you read it) silently pulled a message the agent was about to
  run out of the queue and left a wall of raw prompt sitting in the input box.
  It was reported twice before it was understood: "why do I keep seeing this
  prompt injected into things?" and then "how did that get there? WTF?"

  Two rules, both enforced here:

    * Text in the queue band is TEXT. Not a click target.
    * Anything that fills the composer is an explicitly labeled control, so it
      can only be hit on purpose.
  """
  use ExUnit.Case, async: true

  @chat "lib/loopyard_web/live/workspace_live/components/chat.ex"

  test "the queued message body is not a button" do
    src = File.read!(@chat)

    # Whatever element renders the queued words must not be a control. The
    # row hands the text to <.queued_text> (words + attachment chips); the
    # words render inside that component as {@body}.
    [_, row] = String.split(src, ~s|:for={{text, i} <- Enum.with_index|, parts: 2)
    assert row =~ "<.queued_text text={text} />"
    [_, component] = String.split(src, "def queued_text(assigns) do", parts: 2)
    [before_text, _] = String.split(component, "{@body}", parts: 2)

    # The tag {text} sits inside is the last one opened before it.
    opener = before_text |> String.split("<") |> List.last()

    assert Regex.match?(~r/^p[\s>]/, opener),
           "the queued message's text renders inside <#{String.slice(opener, 0, 12)}…> — " <>
             "it must be a <p>. A control over it dequeues the message on any tap " <>
             "meant to read it."
  end

  test "every composer fill is behind a labeled control" do
    src = File.read!(@chat)

    # Each edit_pending trigger must carry an aria-label naming what it does.
    triggers =
      src
      |> String.split(~s|phx-click="edit_pending"|)
      |> tl()

    assert triggers != [], "expected the queue band to still offer editing"

    for t <- triggers do
      control = String.slice(t, 0, 400)

      assert control =~ "aria-label",
             "a control that writes into the composer has to say so — an " <>
               "unlabeled tap target is how a machine prompt lands in the box"
    end
  end

  @tag timeout: 20_000
  test "only deliberate user actions push fill_input" do
    # Every composer fill must sit in a handle_event (a user did something),
    # never a handle_info (something happened TO us — recovery, resume, a seed).
    for file <- Path.wildcard("lib/loopyard_web/live/**/*.ex"),
        src = File.read!(file),
        String.contains?(src, "fill_input") do
      pushes = length(String.split(src, ~s|push_event(socket, "fill_input"|)) - 1
      handlers = length(String.split(src, ~s|def handle_event("edit_pending"|)) - 1

      assert pushes > 0 and pushes <= handlers,
             "#{file}: fill_input is pushed #{pushes}x but only #{handlers} " <>
               "edit_pending user action(s) exist — the composer is humans-only"
    end
  end
end
