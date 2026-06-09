defmodule Loopyard.Test.ACPFakeTransport do
  @moduledoc """
  In-test ACP transport. Records every outbound message to `test_pid` as
  `{:acp_sent, map}`; the test injects inbound messages by sending
  `{:acp_msg, map}` directly to the `Connection` (the transport's owner).

  With `auto_handshake: true` it auto-replies to `initialize` and
  `session/new` so `Backend.ACP.start_session/1` can complete synchronously;
  the test still drives all prompt-turn traffic.
  """
  @behaviour Loopyard.Agent.Backend.ACP.Transport
  use GenServer

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def send_msg(pid, message), do: GenServer.cast(pid, {:send, message})

  @impl true
  def close(pid), do: GenServer.stop(pid, :normal)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       test_pid: Keyword.fetch!(opts, :test_pid),
       auto_handshake: Keyword.get(opts, :auto_handshake, false)
     }}
  end

  @impl GenServer
  def handle_cast({:send, message}, state) do
    send(state.test_pid, {:acp_sent, message})
    if state.auto_handshake, do: auto_reply(state, message)
    {:noreply, state}
  end

  defp auto_reply(state, %{"method" => "initialize", "id" => id}) do
    send(
      state.owner,
      {:acp_msg, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"protocolVersion" => 1}}}
    )
  end

  defp auto_reply(state, %{"method" => "session/new", "id" => id}) do
    send(
      state.owner,
      {:acp_msg,
       %{
         "jsonrpc" => "2.0",
         "id" => id,
         "result" => %{"sessionId" => "sess-auto", "models" => %{"currentModelId" => "default"}}
       }}
    )
  end

  defp auto_reply(_state, _message), do: :ok
end
