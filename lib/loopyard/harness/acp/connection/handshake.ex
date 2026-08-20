defmodule Loopyard.Harness.ACP.Connection.Handshake do
  @moduledoc """
  The ACP handshake for `Loopyard.Harness.ACP.Connection`: the responses to
  `initialize`, `authenticate`, `session/load` and `session/new`.

  It lives apart from the Connection because it is the one part of the protocol
  with real branching of its own — authenticate-or-not, then resume-or-fresh,
  then a resume that fails and falls back — and because that branching is where
  a new harness's differences actually land.

  Every clause returns the `{:noreply, state}` shape `handle_info/2` returns
  as-is, and reaches back into `Connection` for the shared session plumbing.
  """
  require Logger

  alias Loopyard.Harness.ACP.Connection
  alias Loopyard.Harness.ACP.Connection.{Auth, Models}

  def response(:initialize, msg, state) when not :erlang.is_map_key(:auth_done, state) do
    case Auth.method_id(msg) do
      nil ->
        if offered = Auth.offered(msg) do
          Logger.info(
            "ACP: adapter offers only interactive auth (#{offered}); continuing without it"
          )
        end

        response(:initialize, msg, Map.put(state, :auth_done, true))

      method_id ->
        state = Map.put(state, :auth_done, true)
        # Stash the initialize result: the authenticate response is what
        # resumes the handshake, and it needs the capabilities from here
        # (loadSession) to choose session/load vs session/new.
        state = Map.put(state, :init_result, msg)
        {state, _} = Connection.request(state, "authenticate", %{"methodId" => method_id})
        {:noreply, state}
    end
  end

  # The authenticate round-trip landed — resume the handshake from the stashed
  # initialize result. A failure here is a CREDENTIAL problem, not a transport
  # one, so say so plainly and let the ready-waiters fail rather than retrying
  # a login that will keep failing.
  def response(:authenticate, %{"error" => error}, state) do
    Logger.error("ACP: authenticate failed: #{inspect(error)}")

    {:noreply,
     Connection.reply_waiters(%{state | status: :closed}, {:error, {:auth_failed, error}})}
  end

  def response(:authenticate, _msg, state) do
    response(:initialize, Map.get(state, :init_result, %{}), state)
  end

  def response(:initialize, msg, %{resume: sid} = state)
      when is_binary(sid) and sid != "" do
    # Resume: replay the saved conversation via session/load instead of booting
    # a fresh (amnesic) session/new — this is what makes ACP honor the
    # conversation-continuity invariant across restarts. Only if the adapter
    # advertises the capability; otherwise fall back to a new session so we
    # still boot.
    if Models.load_supported?(msg) do
      {state, _} =
        Connection.request(state, "session/load", %{
          "sessionId" => sid,
          "cwd" => state.cwd,
          "mcpServers" => state.mcp_servers
        })

      {:noreply, state}
    else
      {:noreply, elem(Connection.new_session(state), 0)}
    end
  end

  def response(:initialize, _msg, state) do
    {:noreply, elem(Connection.new_session(state), 0)}
  end

  def response(:session_load, %{"result" => result}, state) do
    # session/load loads the session we named, so its id is our resume id (the
    # adapter may omit it from the result). Any replayed history arrives as
    # session/update notifications with turn == nil first — safely ignored.
    sid = (is_map(result) && result["sessionId"]) || state.resume

    state =
      state
      |> Connection.session_ready(sid, result)
      |> Connection.maybe_set_model(result)

    {:noreply, Connection.reply_waiters(state, :ok)}
  end

  def response(:session_load, %{"error" => error}, state) do
    # Saved session unknown/expired — boot a fresh one so the agent still comes
    # up (as a new conversation) rather than failing to start. LOUD on purpose:
    # this silently drops harness-side conversation continuity (Loopyard's own
    # message history survives in ETS), so it must be visible when it happens.
    Logger.warning(
      "ACP: session/load for #{inspect(state.resume)} failed (#{inspect(error)}); " <>
        "falling back to a FRESH session — harness-side history not restored"
    )

    Loopyard.EventLog.error(
      "harness:acp",
      "Resume failed for session #{inspect(state.resume)} — started fresh instead"
    )

    {:noreply, elem(Connection.new_session(state), 0)}
  end

  def response(:session_new, %{"result" => result}, state) do
    state =
      state
      |> Connection.session_ready(result["sessionId"], result)
      |> Connection.maybe_set_model(result)

    {:noreply, Connection.reply_waiters(state, :ok)}
  end

  def response(:session_new, %{"error" => error}, state) do
    {:noreply, Connection.reply_waiters(%{state | status: :closed}, {:error, error})}
  end

  # Ping response — result OR error both prove the adapter's event loop is
  # alive and serving; reply :pong either way.
end
