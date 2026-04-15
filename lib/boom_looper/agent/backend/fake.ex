defmodule BoomLooper.Agent.Backend.Fake do
  @moduledoc """
  No-op Agent.Backend for tests.

  The real backend (`BoomLooper.Agent.Backend.ClaudeCode`) spawns the
  Node.js Claude CLI subprocess via a Port. With real API auth it
  works; without it the subprocess exits immediately and the stream
  surfaces `{:error, {:provisioning_failed, {:cli_exit, 1}}}` after
  a multi-second retry window. That timing is why `mix test` hangs
  when the dev server isn't configured for the CLI or when tests
  forget to override the backend — every test that happens to boot
  a ChatAgent pays the full timeout.

  This backend:

    * `start_session/1` → spawns a trivial GenServer that holds no state.
    * `stream/2` → returns an empty stream, so the ChatAgent's send_message
      path completes a \"turn\" instantly.
    * `stop/1` → cleanly stops the GenServer.
    * `session_alive?/1` → true while the pid is alive.

  Set as the default in `config/test.exs` so tests that don't opt in
  to a specific backend don't accidentally hit the real CLI.
  """
  @behaviour BoomLooper.Agent.Backend

  use GenServer

  @impl BoomLooper.Agent.Backend
  def start_session(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl BoomLooper.Agent.Backend
  def stream(_session, _prompt), do: []

  @impl BoomLooper.Agent.Backend
  def stop(session) do
    if is_pid(session) and Process.alive?(session) do
      GenServer.stop(session, :normal, 1_000)
    end

    :ok
  end

  @impl BoomLooper.Agent.Backend
  def session_alive?(session), do: is_pid(session) and Process.alive?(session)

  @impl GenServer
  def init(:ok), do: {:ok, %{}}
end
