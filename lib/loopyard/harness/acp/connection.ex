defmodule Loopyard.Harness.ACP.Connection do
  @moduledoc """
  Owns one ACP session: handshake (`initialize` → `session/new`), one prompt
  turn at a time (`session/prompt` → streamed `session/update`s → result),
  and the agent-initiated requests the client must answer (`fs/read_text_file`,
  `fs/write_text_file`, `session/request_permission`).

  Translated `Loopyard.Agent.Event` structs are pushed to the turn's
  subscriber as `{:acp_event, ref, event}`, terminated by
  `{:acp_done, ref, stop_reason}`. `Backend.ACP` wraps that flow as a
  `Stream` so the rest of the agent pipeline is unchanged.

  Permission handling is pluggable via `:permission_mode` — today `:auto_allow`
  (and we still surface a `%Event.PermissionRequest{}` so the #7 UI can later
  intercept); `:ask` (block on a UI decision) is future work.
  """
  use GenServer
  require Logger

  alias Loopyard.Harness.ACP.Translator
  alias Loopyard.Agent.Event

  @protocol_version 1

  # ---- public API ----

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Block until the session is ready (handshake complete) or fails."
  def await_ready(pid, timeout \\ 30_000), do: GenServer.call(pid, :await_ready, timeout)

  @doc "Start a prompt turn; events stream to `subscriber` tagged with `ref`."
  def prompt(pid, text, subscriber, ref),
    do: GenServer.cast(pid, {:prompt, text, subscriber, ref})

  @doc "Cancel the in-flight turn (ACP `session/cancel`) while keeping the session warm."
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  def session_id(pid) do
    GenServer.call(pid, :session_id, 1_000)
  catch
    :exit, _ -> nil
  end

  @doc """
  Protocol-level liveness probe: round-trips a `session/list` request through
  the adapter and returns `:pong` iff its event loop answered. This is the
  difference between "our local GenServer/exec client is alive" and "the
  harness in the container actually responds" — the exec client can outlive a
  dead or wedged in-container adapter (daemon hiccup, EMFILE storm), and a
  pid check alone reported those sessions alive while every turn timed out.
  Any response (result or error) counts: it proves the loop is serving.
  """
  def ping(pid, timeout \\ 2_000) do
    GenServer.call(pid, :ping, timeout)
  catch
    :exit, _ -> {:error, :unresponsive}
  end

  def stop(pid), do: GenServer.stop(pid, :normal)

  # ---- init / handshake ----

  @impl true
  def init(opts) do
    transport_mod = Keyword.get(opts, :transport, Loopyard.Harness.ACP.Transport.Port)
    transport_opts = Keyword.get(opts, :transport_opts, [])

    # Capture the adapter's stderr to a per-session file instead of the old
    # /dev/null default. When the adapter dies or wedges, its dying words are
    # the diagnosis (an EMFILE watcher storm hid here for hours once) — on
    # abnormal close we read the tail back and log it loudly. Cheap: the file
    # is empty in the happy path and removed on clean shutdown.
    stderr_log =
      Keyword.get_lazy(transport_opts, :stderr_log, fn ->
        Path.join(
          System.tmp_dir!(),
          "loopyard-acp-#{:erlang.unique_integer([:positive])}.stderr"
        )
      end)

    transport_opts = Keyword.put(transport_opts, :stderr_log, stderr_log)

    case transport_mod.start_link([owner: self()] ++ transport_opts) do
      {:ok, transport} ->
        state = %{
          transport_mod: transport_mod,
          transport: transport,
          stderr_log: stderr_log,
          next_id: 1,
          pending: %{},
          session_id: nil,
          status: :initializing,
          model: Keyword.get(opts, :model),
          cwd: Keyword.get(opts, :cwd) || File.cwd!(),
          resume: Keyword.get(opts, :resume),
          mcp_servers: Keyword.get(opts, :mcp_servers, []),
          permission_mode: Keyword.get(opts, :permission_mode, :auto_allow),
          waiters: [],
          turn: nil
        }

        # In-container (#5): declaring NO client fs capability makes the
        # adapter use the *container's* filesystem natively, instead of
        # delegating fs/read_text_file back to the host (which can't see
        # /workspace). Host-side we advertise fs and answer the delegation.
        client_caps =
          if Keyword.get(opts, :client_fs, true) do
            %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}}
          else
            %{}
          end

        state =
          request(state, "initialize", %{
            "protocolVersion" => @protocol_version,
            "clientCapabilities" => client_caps
          })
          |> elem(0)

        {:ok, state}

      {:error, reason} ->
        {:stop, {:transport_failed, reason}}
    end
  end

  # ---- calls ----

  @impl true
  def handle_call(:await_ready, _from, %{status: :ready} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, %{status: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call(:await_ready, from, state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

  # Liveness probe. Only a :ready session gets the wire round-trip; anything
  # else answers its status immediately (starting up ≠ dead — the caller
  # decides). The waiter rides in `pending` next to the request id and is
  # replied to when ANY response for that id lands (see handle_response).
  def handle_call(:ping, from, %{status: :ready} = state) do
    {state, id} = request(state, "session/list", %{})
    {:noreply, %{state | pending: Map.put(state.pending, id, {:ping, from})}}
  end

  def handle_call(:ping, _from, state), do: {:reply, {:error, state.status}, state}

  # ---- casts ----

  @impl true
  def handle_cast({:prompt, _text, subscriber, ref}, %{status: status} = state)
      when status != :ready do
    send(subscriber, {:acp_done, ref, {:error, status}})
    {:noreply, state}
  end

  def handle_cast({:prompt, text, subscriber, ref}, state) do
    {state, _id} =
      request(state, "session/prompt", %{
        "sessionId" => state.session_id,
        "prompt" => [%{"type" => "text", "text" => text}]
      })

    turn = %{ref: ref, subscriber: subscriber, translator: Translator.new(model: state.model)}
    {:noreply, %{state | turn: turn}}
  end

  # session/cancel is a NOTIFICATION (no id, no response). The adapter finishes
  # the in-flight session/prompt with stopReason "cancelled", which flows through
  # handle_response(:session_prompt) and finalizes the turn cleanly. The
  # connection stays warm — this interrupts the turn, it doesn't tear down the
  # session. No-op when there's no session yet.
  def handle_cast(:cancel, %{session_id: sid} = state) when is_binary(sid) do
    send_msg(state, %{
      "jsonrpc" => "2.0",
      "method" => "session/cancel",
      "params" => %{"sessionId" => sid}
    })

    {:noreply, state}
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  # ---- inbound messages ----

  @impl true
  def handle_info({:acp_msg, %{"id" => id} = msg}, state) do
    cond do
      Map.has_key?(msg, "method") ->
        # Has both "id" and "method" → an agent-initiated REQUEST we must
        # answer. This MUST be checked before `pending`: JSON-RPC ids are only
        # unique per sender, so an agent request's id can collide with one of
        # our pending outbound ids. Presence of "method" is the only correct
        # request-vs-response discriminator; matching on id first would consume
        # the request as a response, finalize the turn early, and hang the
        # agent's fs-read/permission request.
        handle_agent_request(msg["method"], id, msg["params"] || %{}, state)

      Map.has_key?(state.pending, id) ->
        # No "method" → a response (result/error) to one of our requests.
        {kind, pending} = Map.pop(state.pending, id)
        handle_response(kind, msg, %{state | pending: pending})

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:acp_msg, %{"method" => method} = msg}, state) do
    handle_notification(method, msg["params"] || %{}, state)
  end

  def handle_info({:acp_closed, reason}, state) do
    # The adapter died — its stderr is the diagnosis. Read the tail back and
    # log it LOUDLY (server log + /system/events); without this, failures like
    # the inotify EMFILE storm are invisible ("session/new never answered").
    surface_dying_words(state, reason)

    state = reply_waiters(state, {:error, {:closed, reason}})

    if state.turn do
      # Emit an error SessionResult BEFORE acp_done so upstream sees the turn
      # actually failed (adapter died mid-turn) instead of a clean stop with
      # no result event.
      {_t, events} = Translator.finish(state.turn.translator, {:error, {:closed, reason}})
      Enum.each(events, &send(state.turn.subscriber, {:acp_event, state.turn.ref, &1}))
      send(state.turn.subscriber, {:acp_done, state.turn.ref, {:error, {:closed, reason}}})
    end

    {:stop, :normal, %{state | status: :closed, turn: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---- response routing ----

  defp handle_response(:initialize, msg, %{resume: sid} = state)
       when is_binary(sid) and sid != "" do
    # Resume: replay the saved conversation via session/load instead of booting
    # a fresh (amnesic) session/new — this is what makes ACP honor the
    # conversation-continuity invariant across restarts. Only if the adapter
    # advertises the capability; otherwise fall back to a new session so we
    # still boot.
    if load_supported?(msg) do
      {state, _} =
        request(state, "session/load", %{
          "sessionId" => sid,
          "cwd" => state.cwd,
          "mcpServers" => state.mcp_servers
        })

      {:noreply, state}
    else
      {:noreply, elem(new_session(state), 0)}
    end
  end

  defp handle_response(:initialize, _msg, state) do
    {:noreply, elem(new_session(state), 0)}
  end

  defp handle_response(:session_load, %{"result" => result}, state) do
    # session/load loads the session we named, so its id is our resume id (the
    # adapter may omit it from the result). Any replayed history arrives as
    # session/update notifications with turn == nil first — safely ignored.
    sid = (is_map(result) && result["sessionId"]) || state.resume
    model = get_in(result, ["models", "currentModelId"]) || state.model
    {:noreply, reply_waiters(%{state | session_id: sid, model: model, status: :ready}, :ok)}
  end

  defp handle_response(:session_load, %{"error" => _error}, state) do
    # Saved session unknown/expired — boot a fresh one so the agent still comes
    # up (as a new conversation) rather than failing to start.
    {:noreply, elem(new_session(state), 0)}
  end

  defp handle_response(:session_new, %{"result" => result}, state) do
    sid = result["sessionId"]
    model = get_in(result, ["models", "currentModelId"]) || state.model
    state = %{state | session_id: sid, model: model, status: :ready}
    {:noreply, reply_waiters(state, :ok)}
  end

  defp handle_response(:session_new, %{"error" => error}, state) do
    {:noreply, reply_waiters(%{state | status: :closed}, {:error, error})}
  end

  # Ping response — result OR error both prove the adapter's event loop is
  # alive and serving; reply :pong either way.
  defp handle_response({:ping, from}, _msg, state) do
    GenServer.reply(from, :pong)
    {:noreply, state}
  end

  defp handle_response(:session_prompt, _msg, %{turn: nil} = state), do: {:noreply, state}

  defp handle_response(:session_prompt, msg, state) do
    turn = state.turn
    stop_reason = get_in(msg, ["result", "stopReason"])

    # A JSON-RPC error response means the turn failed; carry that into
    # SessionResult so upstream auto-retry + error surfacing fire.
    error = if match?(%{"error" => e} when not is_nil(e), msg), do: {:error, error_subtype(msg)}
    {_translator, events} = Translator.finish(turn.translator, error)

    Enum.each(events, &send(turn.subscriber, {:acp_event, turn.ref, &1}))
    send(turn.subscriber, {:acp_done, turn.ref, stop_reason || prompt_error(msg)})

    {:noreply, %{state | turn: nil}}
  end

  defp new_session(state),
    do: request(state, "session/new", %{"cwd" => state.cwd, "mcpServers" => state.mcp_servers})

  defp prompt_error(%{"error" => error}), do: {:error, error}
  defp prompt_error(_), do: :unknown

  defp error_subtype(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp error_subtype(%{"error" => %{"code" => c}}), do: "error_#{c}"
  defp error_subtype(_), do: "error"

  # ---- notifications ----

  defp handle_notification("session/update", %{"update" => update}, %{turn: turn} = state)
       when not is_nil(turn) do
    {translator, events} = Translator.step(turn.translator, update)
    Enum.each(events, &send(turn.subscriber, {:acp_event, turn.ref, &1}))
    {:noreply, %{state | turn: %{turn | translator: translator}}}
  end

  defp handle_notification(_method, _params, state), do: {:noreply, state}

  # ---- agent requests we must answer ----

  defp handle_agent_request("fs/read_text_file", id, params, state) do
    # SECURITY: the adapter is untrusted. In host mode we advertise the fs
    # capability, so it can ask us to read ANY path the BEAM user can reach.
    # Clamp the requested path to the session cwd before touching disk.
    case clamp_path(state.cwd, params["path"]) do
      {:ok, safe} ->
        result =
          case File.read(safe) do
            {:ok, content} -> %{"content" => content}
            {:error, reason} -> %{"content" => "ERROR: #{:file.format_error(reason)}"}
          end

        {:noreply, respond(state, id, result)}

      {:error, reason} ->
        {:noreply, respond_error(state, id, -32_602, "path outside workspace: #{reason}")}
    end
  end

  defp handle_agent_request("fs/write_text_file", id, params, state) do
    # SECURITY: same clamp as reads — a host-fs write escape is worse than a
    # read. Reject (JSON-RPC error) instead of silently writing outside cwd.
    case clamp_path(state.cwd, params["path"]) do
      {:ok, safe} ->
        _ = File.write(safe, params["content"] || "")
        {:noreply, respond(state, id, %{})}

      {:error, reason} ->
        {:noreply, respond_error(state, id, -32_602, "path outside workspace: #{reason}")}
    end
  end

  defp handle_agent_request("session/request_permission", id, params, state) do
    options = params["options"] || []

    # Surface for the (future) UI even though we auto-decide for now.
    if state.turn do
      send(
        state.turn.subscriber,
        {:acp_event, state.turn.ref,
         %Event.PermissionRequest{
           request_id: id,
           session_id: params["sessionId"],
           tool_call_id: get_in(params, ["toolCall", "toolCallId"]),
           tool_name: get_in(params, ["toolCall", "title"]),
           input: get_in(params, ["toolCall", "rawInput"]),
           options: normalize_options(options)
         }}
      )
    end

    {:noreply, decide_permission(state, id, options)}
  end

  defp handle_agent_request(method, id, _params, state) do
    Logger.debug("ACP: unhandled agent request #{method}; responding empty")
    {:noreply, respond(state, id, %{})}
  end

  defp decide_permission(%{permission_mode: :auto_allow} = state, id, options) do
    pick =
      Enum.find(options, &String.starts_with?(to_string(&1["kind"] || ""), "allow")) ||
        List.first(options)

    respond(state, id, %{
      "outcome" => %{"outcome" => "selected", "optionId" => pick && pick["optionId"]}
    })
  end

  defp normalize_options(options) do
    Enum.map(options, fn o ->
      %{id: o["optionId"], name: o["name"], kind: o["kind"]}
    end)
  end

  # ---- jsonrpc plumbing ----

  defp request(state, method, params) do
    id = state.next_id
    kind = method_kind(method)
    send_msg(state, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    {%{state | next_id: id + 1, pending: Map.put(state.pending, id, kind)}, id}
  end

  defp respond(state, id, result) do
    send_msg(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    state
  end

  defp respond_error(state, id, code, message) do
    send_msg(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })

    state
  end

  # Resolve an adapter-supplied path against the session cwd and reject any
  # path that escapes the cwd root. Both `..` traversal and absolute paths
  # outside cwd collapse to the same prefix check after `Path.expand`, which
  # normalizes `.`/`..`/symlink-free segments. `cwd` itself is allowed.
  defp clamp_path(_cwd, path) when not is_binary(path) or path == "",
    do: {:error, "missing path"}

  defp clamp_path(cwd, path) do
    root = Path.expand(cwd)
    resolved = Path.expand(path, root)

    if resolved == root or String.starts_with?(resolved, root <> "/") do
      {:ok, resolved}
    else
      {:error, path}
    end
  end

  defp send_msg(state, msg), do: state.transport_mod.send_msg(state.transport, msg)

  defp method_kind("initialize"), do: :initialize
  defp method_kind("session/new"), do: :session_new
  defp method_kind("session/load"), do: :session_load
  defp method_kind("session/prompt"), do: :session_prompt
  defp method_kind(other), do: other

  # Whether the adapter advertised it can replay a saved session (session/load).
  # Absent → false → we use session/new. Guards against booting session/load
  # against an adapter that doesn't support it.
  defp load_supported?(msg) do
    caps = get_in(msg, ["result", "agentCapabilities"]) || %{}
    caps["loadSession"] == true
  end

  defp reply_waiters(state, reply) do
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    %{state | waiters: []}
  end

  # On abnormal close, read the adapter's captured stderr tail and log it —
  # then keep the file for post-mortem. On clean shutdown, remove it.
  @stderr_tail_bytes 2_000

  defp surface_dying_words(%{stderr_log: path}, reason) when is_binary(path) do
    tail =
      case File.read(path) do
        {:ok, ""} ->
          nil

        {:ok, out} ->
          binary_part(
            out,
            max(byte_size(out) - @stderr_tail_bytes, 0),
            min(byte_size(out), @stderr_tail_bytes)
          )

        _ ->
          nil
      end

    if tail do
      Logger.warning(
        "[ACP] adapter closed (#{inspect(reason)}); stderr tail (full: #{path}):\n#{tail}"
      )

      short = binary_part(tail, max(byte_size(tail) - 400, 0), min(byte_size(tail), 400))

      Loopyard.EventLog.error(
        "harness:acp",
        "Adapter closed (#{inspect(reason)}). Stderr: #{short}"
      )
    end

    :ok
  end

  defp surface_dying_words(_state, _reason), do: :ok

  @impl true
  def terminate(reason, state) do
    # Clean stop → the stderr capture served its purpose; don't litter tmp.
    # Abnormal → keep it (surface_dying_words already pointed at the path).
    if reason == :normal and state.status != :closed and is_binary(state[:stderr_log]) do
      _ = File.rm(state.stderr_log)
    end

    :ok
  end
end
