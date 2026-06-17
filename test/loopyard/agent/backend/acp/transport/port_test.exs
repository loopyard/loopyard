defmodule Loopyard.Agent.Backend.ACP.Transport.PortTest do
  @moduledoc """
  Tests for the framing + buffer-safety logic of the real Port transport.

  We exercise the `handle_info/2` framing callbacks directly against a
  hand-built state rather than spawning the adapter subprocess: the security
  property under test (the partial-frame buffer cannot grow unbounded) lives
  entirely in the `:noeol` chunk handler and needs no real Port.

  `port` in the matched messages is just the opaque term stored in state —
  we use a fake reference so the `%{port: port}` guard matches.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Agent.Backend.ACP.Transport.Port, as: T

  # @max_buffer_bytes in the module under test (kept in sync with the source).
  @cap 16_000_000

  defp state(owner), do: %{owner: owner, port: :fake_port, buf: ""}

  test "a completed line (:eol) is delivered to the owner as a decoded message" do
    s = state(self())
    frame = Jason.encode!(%{"hello" => "world"})

    assert {:noreply, s2} = T.handle_info({:fake_port, {:data, {:eol, frame}}}, s)
    assert s2.buf == ""
    assert_receive {:acp_msg, %{"hello" => "world"}}
  end

  test "partial (:noeol) chunks accumulate in the buffer below the cap" do
    s = state(self())

    {:noreply, s2} = T.handle_info({:fake_port, {:data, {:noeol, "abc"}}}, s)
    {:noreply, s3} = T.handle_info({:fake_port, {:data, {:noeol, "def"}}}, s2)

    assert s3.buf == "abcdef"
    refute_received {:acp_closed, _}
  end

  test "an oversized partial frame is bounded: the transport errors+closes instead of buffering" do
    s = state(self())
    # Pre-fill the buffer near the cap, then push it over with one more chunk.
    s = %{s | buf: String.duplicate("x", @cap - 5)}

    assert {:stop, :normal, _s} =
             T.handle_info({:fake_port, {:data, {:noeol, String.duplicate("y", 100)}}}, s)

    # Owner is told the transport failed rather than the buffer growing forever.
    assert_receive {:acp_closed, {:error, :frame_too_large}}
  end
end
