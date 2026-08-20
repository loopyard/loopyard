defmodule Loopyard.Harness.ACP.Connection.Auth do
  @moduledoc """
  ACP `authenticate` method selection for `Loopyard.Harness.ACP.Connection`.

  Some adapters won't open a session until the client has authenticated. The
  `initialize` result advertises `authMethods`; the client picks one and calls
  `authenticate` with its `methodId`. Skip that and `session/new` comes back
  `-32000 Authentication required` even when a perfectly good credential is
  sitting in the container's environment — which is exactly what codex-acp does.

  Selection is DATA-DRIVEN, never per-vendor: we take the first advertised
  method that Loopyard can satisfy without a human at a keyboard. Adapters that
  advertise nothing (claude-agent-acp, unless the client declares terminal or
  gateway auth capability — we declare neither) are unaffected: no method, no
  `authenticate` call, same handshake as before.

  ## Why an allowlist and not "first method wins"

  The interactive methods are the majority — `chat-gpt` opens a browser,
  `chat-gpt-device-code` needs a code typed in. Picking one of those inside a
  headless container doesn't fail fast; it HANGS the handshake on a login nobody
  can complete, until the handshake deadline kills the session and the restart
  loop tries it again forever. An allowlist means an adapter offering only
  interactive methods is reported as "needs a credential" — which a human can
  act on — instead of wedging.

  (`NO_BROWSER=1`, set per-harness in `Loopyard.Harness.Catalog`, already stops
  codex-acp from advertising the browser method at all. This allowlist is the
  belt to that suspenders: it holds for adapters we haven't met yet.)
  """

  # Methods that authenticate from ambient credentials — an API key in the
  # container env, or a preconfigured gateway. No human, no round-trip.
  @non_interactive ~w(api-key gateway)

  @doc """
  The `methodId` to authenticate with, or `nil` when we should go straight to
  `session/new`.

  `nil` covers both "the adapter needs no auth" and "it needs auth we can't
  supply here" — the caller proceeds either way, and an adapter that really does
  need credentials answers `session/new` with a clear auth error we surface as
  itself.
  """
  @spec method_id(map()) :: String.t() | nil
  def method_id(msg) when is_map(msg) do
    msg
    |> advertised_methods()
    |> Enum.map(&method_id_of/1)
    |> Enum.find(&(&1 in @non_interactive))
  end

  def method_id(_), do: nil

  @doc """
  Human-readable summary of what the adapter offered, for the log line when we
  can't satisfy any of it. Empty list → nil (nothing to say).
  """
  @spec offered(map()) :: String.t() | nil
  def offered(msg) do
    case msg |> advertised_methods() |> Enum.map(&method_id_of/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      ids -> Enum.join(ids, ", ")
    end
  end

  defp advertised_methods(msg) do
    case get_in(msg, ["result", "authMethods"]) do
      methods when is_list(methods) -> methods
      _ -> []
    end
  end

  defp method_id_of(%{"id" => id}) when is_binary(id), do: id
  defp method_id_of(_), do: nil
end
