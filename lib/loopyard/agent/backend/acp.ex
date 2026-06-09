defmodule Loopyard.Agent.Backend.ACP do
  @moduledoc """
  Agent backend that drives a *real* coding harness (Claude Code today, Codex
  next) over the **Agent Client Protocol** instead of reimplementing the agent
  loop. Implements the same `Loopyard.Agent.Backend` behaviour as
  `Backend.ClaudeCode`, so the ChatAgent / StreamHandler / multiplayer stack is
  unchanged — only the event *source* differs.

  This is Foundation A of the north-star (issue #3). Host-side today; the
  in-container variant (#5) swaps only the transport `cmd`
  (`docker exec -i <container> <adapter>`), so the harness runs where the code
  lives and native tools work without the MCP filesystem proxy.

  Status: handshake + streamed prompt turns + permission/fs round-trips are
  implemented and tested against a fake transport. Not yet wired as the default
  backend. Known gaps (tracked on #3/#6): mapping Loopyard's system prompt +
  tool policy onto ACP, token-usage surfacing (claude-code-acp doesn't expose
  it — see cost-visibility decision), and the `:ask` permission mode (#7).
  """
  @behaviour Loopyard.Agent.Backend

  alias Loopyard.Agent.Backend.ACP.Connection

  @ready_timeout 30_000
  @turn_timeout 600_000

  @impl true
  def start_session(opts) do
    conn_opts =
      [
        cwd: Keyword.get(opts, :cwd),
        resume: Keyword.get(opts, :resume),
        permission_mode: acp_permission_mode(opts)
      ]
      |> maybe_put(:transport, Keyword.get(opts, :transport))
      |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))
      |> maybe_put(:model, Keyword.get(opts, :model))

    with {:ok, conn} <- Connection.start_link(conn_opts),
         :ok <- Connection.await_ready(conn, @ready_timeout) do
      {:ok, conn}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stream(conn, prompt) do
    Stream.resource(
      fn ->
        ref = make_ref()
        Connection.prompt(conn, prompt, self(), ref)
        ref
      end,
      fn ref ->
        receive do
          {:acp_event, ^ref, event} -> {[event], ref}
          {:acp_done, ^ref, _stop} -> {:halt, ref}
        after
          @turn_timeout -> {:halt, ref}
        end
      end,
      fn _ref -> :ok end
    )
  end

  @impl true
  def stop(conn) do
    if is_pid(conn) and Process.alive?(conn), do: Connection.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def session_alive?(conn), do: is_pid(conn) and Process.alive?(conn)

  @impl true
  def session_id(conn) do
    if is_pid(conn) and Process.alive?(conn), do: Connection.session_id(conn)
  end

  # Loopyard's :accept_edits / dangerously_skip_permissions map to auto-allow
  # for now; the #7 work introduces an :ask mode that blocks on a UI decision.
  defp acp_permission_mode(_opts), do: :auto_allow

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
