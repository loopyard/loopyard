defmodule Loopyard.Harness.ACP.Transport.Port do
  @moduledoc """
  Real ACP transport: spawns the adapter as an OS subprocess over an Erlang
  Port and exchanges newline-delimited JSON-RPC on its stdio.

  Verified host-side against `@zed-industries/claude-code-acp@0.16.2` (see
  `priv/spikes/acp_smoke.exs`). `CLAUDECODE` is unset in the child env so the
  adapter doesn't refuse to launch as a "nested" Claude Code session.

  The in-container variant (#5) is the same idea with a different `cmd` —
  `docker exec -i <container> <adapter>` — so the harness runs where the code
  lives. Keep that seam in mind: only `cmd` changes.
  """
  use GenServer

  @behaviour Loopyard.Harness.ACP.Transport

  # Package was renamed to @agentclientprotocol/claude-agent-acp; we default
  # to the verified name and let callers override.
  @default_cmd "npx -y @zed-industries/claude-code-acp"

  # SECURITY: hard ceiling on the partial-frame buffer. `{:line, 8_000_000}`
  # caps a single delivered chunk, but `:noeol` continuations accumulate in
  # `state.buf` with no inherent limit — an adapter that never sends a newline
  # could grow it without bound and OOM the BEAM. On exceed we error+close the
  # transport rather than buffer forever. 16MB leaves headroom over the 8MB
  # line cap while staying small enough to never threaten the VM.
  @max_buffer_bytes 16_000_000

  @impl Loopyard.Harness.ACP.Transport
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl Loopyard.Harness.ACP.Transport
  def send_msg(pid, message), do: GenServer.cast(pid, {:send, message})

  @impl Loopyard.Harness.ACP.Transport
  def close(pid), do: GenServer.stop(pid, :normal)

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    cmd = Keyword.get(opts, :cmd, @default_cmd)
    stderr = Keyword.get(opts, :stderr_log, "/dev/null")

    shell =
      ~s(unset CLAUDECODE CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT; exec #{cmd} 2>"#{stderr}")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 8_000_000},
        args: ["-c", shell]
      ])

    {:ok, %{owner: owner, port: port, buf: ""}}
  end

  @impl GenServer
  def handle_cast({:send, message}, state) do
    Port.command(state.port, Jason.encode!(message) <> "\n")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buf <> chunk
    deliver(state.owner, line)
    {:noreply, %{state | buf: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    buf = state.buf <> chunk

    if byte_size(buf) > @max_buffer_bytes do
      # Malicious/buggy harness streaming an endless line with no newline.
      # Treat it as a transport failure: notify the owner and stop so we
      # don't accumulate unboundedly.
      send(state.owner, {:acp_closed, {:error, :frame_too_large}})
      {:stop, :normal, state}
    else
      {:noreply, %{state | buf: buf}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    send(state.owner, {:acp_closed, {:exit_status, code}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp deliver(owner, line) do
    case line |> String.trim() |> decode() do
      {:ok, map} -> send(owner, {:acp_msg, map})
      :skip -> :ok
    end
  end

  defp decode(""), do: :skip

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> :skip
    end
  end
end
