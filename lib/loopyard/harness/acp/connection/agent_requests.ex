defmodule Loopyard.Harness.ACP.Connection.AgentRequests do
  @moduledoc """
  The agent-initiated JSON-RPC requests a `Loopyard.Harness.ACP.Connection`
  must answer: `fs/read_text_file`, `fs/write_text_file` (host mode only —
  both clamped to the session cwd), `session/request_permission` (auto-allow
  today, with the one Discuss exception: an ExitPlanMode `switch_mode` request
  is answered "keep planning" while the human asked for plan mode) and
  `elicitation/create` (the harness's native AskUserQuestion, routed to the
  agent's question card).

  Split out of the Connection like `Handshake`: every clause returns the
  `{:noreply, state}` shape `handle_info/2` returns as-is, and reaches back
  into `Connection` for the JSON-RPC plumbing (`respond/3`, `respond_error/4`).
  """
  require Logger

  alias Loopyard.Agent.Event
  alias Loopyard.Harness.ACP.Connection
  alias Loopyard.Harness.ACP.Connection.Modes

  def handle("fs/read_text_file", id, params, state) do
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

        {:noreply, Connection.respond(state, id, result)}

      {:error, reason} ->
        {:noreply,
         Connection.respond_error(state, id, -32_602, "path outside workspace: #{reason}")}
    end
  end

  def handle("fs/write_text_file", id, params, state) do
    # SECURITY: same clamp as reads — a host-fs write escape is worse than a
    # read. Reject (JSON-RPC error) instead of silently writing outside cwd.
    case clamp_path(state.cwd, params["path"]) do
      {:ok, safe} ->
        _ = File.write(safe, params["content"] || "")
        {:noreply, Connection.respond(state, id, %{})}

      {:error, reason} ->
        {:noreply,
         Connection.respond_error(state, id, -32_602, "path outside workspace: #{reason}")}
    end
  end

  def handle("session/request_permission", id, params, state) do
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

    {:noreply, decide_permission(state, id, params, options)}
  end

  def handle("elicitation/create", id, params, state) do
    # The harness's native AskUserQuestion, surfaced as an ACP form elicitation
    # (we advertise elicitation.form iff state.agent_id is set). Route it to the
    # agent's question card via the same broker the MCP ask_user tool uses —
    # the human answers/skips per question, and the form response feeds the
    # answers back into the tool's own input. Questions.ask BLOCKS (up to
    # 10 min), so it runs in a Task: the connection keeps streaming the turn,
    # and the JSON-RPC response is sent when the answer lands (handle_cast
    # below). Decline (= "user skipped") on anything we can't present — cancel
    # would abort the whole tool call.
    alias Loopyard.Harness.QuestionAdapter.AcpElicitation

    with agent_id when is_binary(agent_id) <- state.agent_id,
         "form" <- params["mode"] || "form",
         {:ok, questions} <- AcpElicitation.parse(params) do
      conn = self()

      # Supervised, and the JSON-RPC response is guaranteed: if ANYTHING in the
      # ask/render path raises (malformed selection, broker hiccup), we still
      # answer with a decline — an unanswered elicitation wedges the agent's
      # whole turn on a request that will never resolve.
      Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
        result =
          try do
            case Loopyard.Harness.Questions.ask(agent_id, questions) do
              {:ok, selections} ->
                %{
                  "action" => "accept",
                  "content" => AcpElicitation.render_content(questions, selections)
                }

              {:error, :timeout} ->
                %{"action" => "decline"}
            end
          rescue
            e ->
              Logger.warning("ACP elicitation crashed: #{Exception.message(e)} — declining")
              %{"action" => "decline"}
          catch
            kind, reason ->
              Logger.warning("ACP elicitation #{kind}: #{inspect(reason)} — declining")
              %{"action" => "decline"}
          end

        GenServer.cast(conn, {:elicitation_result, id, result})
      end)

      {:noreply, state}
    else
      _ ->
        Logger.warning(
          "ACP: unpresentable elicitation/create; declining (#{inspect(params["mode"])})"
        )

        {:noreply, Connection.respond(state, id, %{"action" => "decline"})}
    end
  end

  def handle(method, id, _params, state) do
    Logger.debug("ACP: unhandled agent request #{method}; responding empty")
    {:noreply, Connection.respond(state, id, %{})}
  end

  defp decide_permission(%{permission_mode: :auto_allow} = state, id, params, options) do
    # DISCUSS keeps planning. The harness's ExitPlanMode arrives as a permission
    # request whose tool call is `kind: "switch_mode"` (ACP's own vocabulary —
    # never the tool's name). While the human has the composer on Discuss
    # (`desired_mode` is the plan mode), leaving plan mode is THEIR call, not
    # the model's: pick the reject option ("No, keep planning"), so the plan
    # stays a plan until they flip to Build. Every other request is
    # auto-allowed as before. Mirrors ACP's sort: allow_once is listed first.
    switch_mode? = get_in(params, ["toolCall", "kind"]) == "switch_mode"
    plan = Modes.plan_mode_id(state.available_modes)
    discussing? = is_binary(plan) and state.desired_mode == plan

    reject =
      switch_mode? and discussing? and
        Enum.find(options, &String.starts_with?(to_string(&1["kind"] || ""), "reject"))

    pick =
      reject ||
        Enum.find(options, &String.starts_with?(to_string(&1["kind"] || ""), "allow")) ||
        List.first(options)

    Connection.respond(state, id, %{
      "outcome" => %{"outcome" => "selected", "optionId" => pick && pick["optionId"]}
    })
  end

  defp normalize_options(options) do
    Enum.map(options, fn o ->
      %{id: o["optionId"], name: o["name"], kind: o["kind"]}
    end)
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
end
