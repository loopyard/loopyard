defmodule Loopyard.Harness.ACP.Transport do
  @moduledoc """
  A transport carries newline-delimited JSON-RPC between Loopyard and an ACP
  agent process. It owns framing + (de)serialization so the `Connection`
  works in terms of decoded maps.

  A transport must:

    * forward each decoded inbound message to its `owner` as `{:acp_msg, map}`
    * forward shutdown to its `owner` as `{:acp_closed, reason}`
    * accept `send_msg/2` to encode + write an outbound message

  Two implementations: `Transport.Port` (real — spawns the adapter over a
  Port; the in-container variant will `docker exec -i`) and a test fake.
  """

  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback send_msg(transport :: pid(), message :: map()) :: :ok
  @callback close(transport :: pid()) :: :ok
end
