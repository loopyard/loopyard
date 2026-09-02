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

  # Remember what the adapter offered, but do NOT authenticate yet — see the
  # session/new error clause below for why this is on-demand.
  def response(:initialize, msg, state) when not :erlang.is_map_key(:init_result, state) do
    state = state |> Map.put(:init_result, msg) |> Map.put(:auth_method, Auth.method_id(msg))
    response(:initialize, msg, state)
  end

  # The authenticate round-trip landed — retry the session that provoked it.
  # A failure here is a CREDENTIAL problem, not a transport one, so say so
  # plainly and let the ready-waiters fail rather than retrying a login that
  # will keep failing.
  def response(:authenticate, %{"error" => error}, state) do
    Logger.error("ACP: authenticate failed: #{inspect(error)}")

    {:noreply,
     Connection.reply_waiters(%{state | status: :closed}, {:error, {:auth_failed, error}})}
  end

  # Authenticated — now redo the resume-or-fresh decision from the top, NOT a
  # blind session/new: if it was session/load that got refused, a fresh
  # session here would quietly throw away the harness-side history that the
  # credential just unlocked. The one exception is a load that already failed
  # for a non-auth reason (expired id) — repeating it would only fail again.
  def response(:authenticate, _msg, state) do
    if Map.get(state, :load_failed, false) do
      {:noreply, elem(Connection.new_session(state), 0)}
    else
      response(:initialize, Map.fetch!(state, :init_result), state)
    end
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
    case try_authenticate(state, error) do
      # Adapters that gate session/load behind auth (codex-acp does, exactly
      # like session/new) refuse the resume before ever looking at the id.
      # That's not an expired session — authenticate and load again, so a
      # Loopyard restart doesn't cost a Codex agent its harness-side history.
      {:ok, state} ->
        {:noreply, state}

      :skip ->
        # Saved session unknown/expired — boot a fresh one so the agent still
        # comes up (as a new conversation) rather than failing to start. LOUD
        # on purpose: this silently drops harness-side conversation continuity
        # (Loopyard's own message history survives in ETS), so it must be
        # visible when it happens.
        Logger.warning(
          "ACP: session/load for #{inspect(state.resume)} failed (#{inspect(error)}); " <>
            "falling back to a FRESH session — harness-side history not restored"
        )

        Loopyard.EventLog.error(
          "harness:acp",
          "Resume failed for session #{inspect(state.resume)} — started fresh instead"
        )

        {:noreply, elem(Connection.new_session(Map.put(state, :load_failed, true)), 0)}
    end
  end

  def response(:session_new, %{"result" => result}, state) do
    state =
      state
      |> Connection.session_ready(result["sessionId"], result)
      |> Connection.maybe_set_model(result)

    {:noreply, Connection.reply_waiters(state, :ok)}
  end

  # AUTH ON DEMAND. An adapter advertises every auth method it *supports*, not
  # the ones you still need — codex-acp lists `api-key` even when you are
  # already signed in via ChatGPT. Authenticating eagerly off that list forced
  # an API-key login over a perfectly good existing session and failed with
  # "CODEX_API_KEY or OPENAI_API_KEY is not set" for a user who needs neither.
  #
  # So the adapter gets to tell us: only when session/new comes back
  # "Authentication required" do we authenticate, and then retry it once. An
  # existing login never sees an authenticate call at all.
  def response(:session_new, %{"error" => error}, state) do
    case try_authenticate(state, error) do
      {:ok, state} ->
        {:noreply, state}

      :skip ->
        if auth_required?(error) and is_nil(Map.get(state, :auth_method)) do
          Logger.error(
            "ACP: session needs auth but no non-interactive method is offered" <>
              case Auth.offered(Map.get(state, :init_result, %{})) do
                nil -> ""
                offered -> " (adapter offers: #{offered})"
              end
          )
        end

        {:noreply, Connection.reply_waiters(%{state | status: :closed}, {:error, error})}
    end
  end

  # Send `authenticate` ONCE, and only for an auth refusal we have a headless
  # method for. `:skip` means the caller handles the error as itself — no
  # method, not an auth error, or we already tried and it didn't take.
  defp try_authenticate(state, error) do
    method = Map.get(state, :auth_method)

    if auth_required?(error) and is_binary(method) and not Map.get(state, :auth_tried, false) do
      state = Map.put(state, :auth_tried, true)
      {state, _} = Connection.request(state, "authenticate", %{"methodId" => method})
      {:ok, state}
    else
      :skip
    end
  end

  # JSON-RPC -32000 is the ACP "Authentication required" code; match the
  # message too, since an adapter may use a different code for the same thing.
  defp auth_required?(%{"code" => -32_000}), do: true

  defp auth_required?(%{"message" => m}) when is_binary(m),
    do: String.contains?(m, "Authentication required")

  defp auth_required?(_), do: false
end
