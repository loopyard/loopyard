defmodule LoopyardWeb.SendContractTest do
  @moduledoc """
  A UI send must be ACKNOWLEDGED. No composer may fire-and-forget.

  The incident: the operator's composer called `send_message/2` — a cast — so
  the LiveView replied `ok: true` and the box cleared before the agent had
  received anything. When the agent then crashed handling that message, it was
  gone: no ack, no error, no transitional state. From the outside, typing did
  NOTHING, and nothing in the logs was surfaced to the person it happened to.

  `send_message/2` (cast) is documented as fine for internal/eval callers.
  A UI path is different in kind: only a CALL can tell someone their text
  landed, which is the whole basis of "the box keeps your text until the server
  says it has it".
  """
  use ExUnit.Case, async: true

  @composers Path.wildcard("lib/loopyard_web/**/*.ex")

  test "no LiveView composer sends with the fire-and-forget cast" do
    offenders =
      for path <- @composers,
          src = File.read!(path),
          # The cast, called on the ChatAgent client from the web layer.
          Regex.match?(~r/ChatAgent\.send_message\(/, src),
          do: Path.relative_to_cwd(path)

    assert offenders == [],
           """
           These send into the void — a cast can't tell the user their message
           landed, so a crash while handling it looks like nothing happened.

           Use ChatAgent.enqueue_message/2 (a call) and reply ok:false with a
           note when it fails, exactly as the workspace composer does.

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "anything that can ack a send can also refuse one" do
    # Scoped to the modules that actually ANSWER the composer — the ones that
    # reply ok: true. A helper that merely calls enqueue_message and hands the
    # result back isn't the acking party. An ack path that can only ever say
    # ok: true is the same bug wearing a call: it clears the box regardless of
    # what the agent said.
    for path <- @composers,
        src = File.read!(path),
        Regex.match?(~r/ok:\s*true/, src) do
      assert Regex.match?(~r/ok:\s*false/, src),
             "#{Path.relative_to_cwd(path)} can reply ok: true but never ok: false — " <>
               "a send that cannot fail visibly will fail invisibly."
    end
  end
end
