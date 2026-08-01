defmodule LoopyardWeb.ReviewLive do
  @moduledoc """
  `/review` — the Reviewer (plans/question-review.md): catch up on everything
  waiting on you, ONE decision per slide. A multi-question ask fans out into
  one slide per question; approvals and secrets are one slide each. Prev/next,
  a position indicator, and answer → settled beat → advance. Live: leave it
  open in a tab and new items join the line as agents ask.

  Built on the FOCUSED VIEW shell (`LoopyardWeb.Components.FocusedView`) — the
  subject (project · workspace) is prominent, the content sits alone at the
  reading measure. Sourced from `Loopyard.Attention.line/0` (durable,
  card-sourced), so nothing waiting can be missing. `?workspace=<id>` scopes to
  one workspace; `?q=<agent>:<msg>` starts at a specific item.

  The current slide is keyed `{agent_id, msg_id, q_id}` so queue churn never
  yanks the screen; when the current decision settles it holds for a beat
  (you see it take), then advances to the next pending slide.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.Events
  alias LoopyardWeb.Components.FocusedView
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  @tick_ms 3_000
  @advance_ms 900

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    # Resource routes: /review · /review/:agent_id/:msg_id ·
    # /projects/:project_id/workspaces/:workspace_id/review.
    scope = params["workspace_id"]
    history? = socket.assigns.live_action == :history
    socket = socket |> assign(:scope, scope) |> assign(:history?, history?)
    slides = if history?, do: history_slides(), else: slides(scope)

    current =
      with aid when is_binary(aid) <- params["agent_id"],
           mid when is_binary(mid) <- params["msg_id"],
           %{} = slide <- Enum.find(slides, &(&1.agent_id == aid and &1.msg_id == mid)) do
        slide.key
      else
        _ -> first_key(slides)
      end

    {:ok,
     socket
     |> assign(:slides, slides)
     |> assign(:current, current)
     |> assign(:subscribed, MapSet.new())
     |> assign(:last_path, nil)
     |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: scope)
     |> sync_secret_scope()
     |> track_current()}
  end

  # Answer updates are CASTS — the card flips via a MessageUpdated broadcast,
  # not synchronously with the click. Subscribe to the current slide's agent so
  # the settle renders the instant the update lands (no 3s tick latency). Also
  # remember the slide's chat path — it's where "done reviewing" returns to.
  defp track_current(socket) do
    case current_slide(socket) do
      %{agent_id: aid} = slide when is_binary(aid) ->
        socket =
          if connected?(socket) and not MapSet.member?(socket.assigns.subscribed, aid) do
            Events.ChatAgentMessage.subscribe(aid)
            assign(socket, :subscribed, MapSet.put(socket.assigns.subscribed, aid))
          else
            socket
          end

        assign(socket, :last_path, slide[:path] || socket.assigns.last_path)

      _ ->
        socket
    end
  end

  # ── the slide deck ────────────────────────────────────────────────────────
  #
  # One slide per DECISION: each pending question of a multi-question ask is
  # its own slide; an approval or secret is one slide. Slides carry everything
  # the render needs except the live message (fetched fresh per render).

  defp slides(scope) do
    Loopyard.Attention.line()
    |> Enum.filter(&(is_nil(scope) or &1.workspace_id == scope))
    |> Enum.flat_map(&item_slides/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # The TIME MACHINE deck: every question/approval/secret ever asked (recent
  # tail per agent), any status, newest first — one slide per CARD (settled
  # receipts render whole). "We have them around anyway, so might as well."
  defp history_slides do
    ws_names =
      for p <- Loopyard.ProjectRegistry.list_projects(),
          ws <- Loopyard.WorkspaceRegistry.list_workspaces(p.id),
          into: %{} do
        {ws.id, %{project_name: p.name, workspace_name: ws.name, project_id: p.id}}
      end

    for %{id: aid} = st <- Loopyard.ChatAgent.list_agent_summaries(),
        not String.contains?(to_string(st[:name] || ""), "test"),
        msg <- st |> Map.get(:messages, []) |> Enum.take(-200),
        msg[:role] in [:question, :approval, :secret_request] do
      ws = Map.get(ws_names, st[:workspace_id], %{})

      item = %{
        kind: history_kind(msg.role),
        agent_id: aid,
        msg: msg,
        workspace_id: st[:workspace_id],
        project_name: ws[:project_name],
        workspace_name: ws[:workspace_name],
        agent_name: st[:name] || "Agent",
        path: history_path(ws, st),
        asked_at: msg[:timestamp] || DateTime.from_unix!(0)
      }

      slide(item, nil)
    end
    |> Enum.sort_by(& &1.asked_at, {:desc, DateTime})
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp history_kind(:question), do: :question
  defp history_kind(:secret_request), do: :secret
  defp history_kind(:approval), do: :approval

  defp history_path(%{project_id: pid}, st) when is_binary(pid),
    do: "/projects/#{pid}/workspaces/#{st[:workspace_id]}/agents/#{st[:id]}"

  defp history_path(_ws, _st), do: "/operator"

  defp item_slides(%{kind: :question, msg: %{} = msg} = item) do
    for q <- msg[:questions] || [], q.id not in (msg[:done] || []) do
      slide(item, q.id)
    end
  end

  defp item_slides(%{msg: %{}} = item), do: [slide(item, nil)]
  defp item_slides(_), do: []

  defp slide(item, q_id) do
    %{
      key: {item.agent_id, item.msg.id, q_id},
      agent_id: item.agent_id,
      msg_id: item.msg.id,
      q_id: q_id,
      kind: item.kind,
      workspace_id: item.workspace_id,
      project_name: item.project_name,
      workspace_name: item.workspace_name,
      agent_name: item.agent_name,
      path: item.path,
      asked_at: item.asked_at
    }
  end

  defp first_key(slides), do: slides |> List.first() |> then(&(&1 && &1.key))

  # ── queue upkeep ─────────────────────────────────────────────────────────

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  # Activity events arrive from EVERY agent — a busy fleet fires them in
  # bursts. Coalesce: arm one delayed refresh instead of scanning per event
  # (the deck rarely changes; the scan isn't free).
  def handle_info(%Events.Activity.Event{}, socket) do
    if socket.assigns[:refresh_armed?] do
      {:noreply, socket}
    else
      Process.send_after(self(), :coalesced_refresh, 250)
      {:noreply, assign(socket, :refresh_armed?, true)}
    end
  end

  def handle_info(:coalesced_refresh, socket),
    do: {:noreply, socket |> assign(:refresh_armed?, false) |> refresh()}

  # The answer's card update just landed — settle NOW, not on the next tick.
  def handle_info(%Events.ChatAgentMessage.MessageUpdated{}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(%Events.ChatAgentMessage.Message{}, socket), do: {:noreply, refresh(socket)}

  # The settled beat is over — advance to the next pending slide.
  def handle_info(:advance, socket) do
    slides = slides(socket.assigns.scope)

    if slides == [] do
      # Line cleared — reviewing is DONE. Return to the work instead of
      # dead-ending on an empty screen: the last item's chat, else the operator.
      {:noreply, push_navigate(socket, to: socket.assigns.last_path || "/operator")}
    else
      {:noreply,
       socket
       |> assign(:slides, slides)
       |> assign(:current, first_key(slides))
       |> sync_secret_scope()
       |> track_current()}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # If the CURRENT slide just settled (left the deck), hold it for a beat so
  # the answer visibly takes, then advance.
  defp refresh(socket) do
    slides =
      if socket.assigns.history?,
        do: history_slides(),
        else: slides(socket.assigns.scope)

    cur = socket.assigns.current

    cond do
      is_nil(cur) ->
        socket
        |> assign(:slides, slides)
        |> assign(:current, first_key(slides))
        |> sync_secret_scope()

      Enum.any?(slides, &(&1.key == cur)) ->
        assign(socket, :slides, slides)

      socket.assigns.history? ->
        # The time machine never auto-advances — a settled card staying put
        # IS the point.
        assign(socket, :slides, slides)

      true ->
        Process.send_after(self(), :advance, @advance_ms)
        assign(socket, :slides, slides)
    end
  end

  # ── navigation + decisions ───────────────────────────────────────────────

  @impl true
  def handle_event("nav", %{"dir" => dir}, socket) do
    slides = socket.assigns.slides
    idx = Enum.find_index(slides, &(&1.key == socket.assigns.current)) || 0

    next =
      case dir do
        "next" -> min(idx + 1, length(slides) - 1)
        _ -> max(idx - 1, 0)
      end

    {:noreply,
     socket
     |> assign(:current, slides |> Enum.at(next) |> then(&(&1 && &1.key)))
     |> sync_secret_scope()
     |> track_current()}
  end

  def handle_event("decide_approval", %{"approval_id" => id, "decision" => decision}, socket) do
    decision = if decision == "approve", do: :approve, else: :deny

    case current_slide(socket) do
      %{agent_id: aid} -> LoopyardWeb.Live.ApprovalActions.decide(aid, id, decision)
      _ -> :ok
    end

    {:noreply, socket}
  end

  defp current_slide(socket) do
    Enum.find(socket.assigns.slides, &(&1.key == socket.assigns.current)) ||
      rehydrate(socket.assigns.current)
  end

  # The settled-beat case: the slide left the deck but stays on screen — carry
  # enough to keep rendering it from the current key.
  defp rehydrate(nil), do: nil

  defp rehydrate({aid, mid, q_id}) do
    %{key: {aid, mid, q_id}, agent_id: aid, msg_id: mid, q_id: q_id, kind: nil, path: nil}
    |> Map.merge(%{workspace_id: nil, project_name: nil, workspace_name: nil, agent_name: nil})
  end

  # Secrets submitted here scope to the CURRENT slide's workspace.
  defp sync_secret_scope(socket) do
    assign(
      socket,
      :consent_secret_scope,
      case current_slide(socket) do
        %{workspace_id: ws} when is_binary(ws) -> ws
        _ -> socket.assigns[:scope]
      end
    )
  end

  defp live_msg(nil), do: nil

  defp live_msg(%{agent_id: aid, msg_id: mid}) do
    Loopyard.ChatAgent.get_message(aid, mid)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    slide = Enum.find(assigns.slides, &(&1.key == assigns.current)) || rehydrate(assigns.current)
    msg = live_msg(slide)
    idx = Enum.find_index(assigns.slides, &(&1.key == assigns.current))
    q = slide && slide.q_id && msg && Enum.find(msg[:questions] || [], &(&1.id == slide.q_id))

    assigns =
      assigns
      |> assign(:slide, slide)
      |> assign(:msg, msg)
      |> assign(:q, q)
      |> assign(:idx, idx)
      |> assign(:count, length(assigns.slides))

    ~H"""
    <FocusedView.layout
      label={(@history? && "Time machine") || "Review"}
      position={@count > 0 && "#{(@idx || 0) + 1} of #{@count}"}
      mode={:operator}
      crumbs={[{"Operator", "/operator"}]}
    >
      <:nav>
        <%!-- Flip between the pending deck and the TIME MACHINE (all past
    questions — they're durable anyway, so they're traversable). --%>
        <.link
          navigate={(@history? && "/review") || "/review/history"}
          class="focus-ring tap-target inline-flex items-center justify-center w-9 h-9 rounded-sm text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          aria-label={(@history? && "Back to pending") || "Question history"}
          title={(@history? && "Back to pending") || "Question history"}
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-4.5 h-4.5" aria-hidden="true">
            <path
              fill-rule="evenodd"
              d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm.75-13a.75.75 0 0 0-1.5 0v5c0 .27.144.518.378.651l3.5 2a.75.75 0 1 0 .744-1.302L10.75 9.565V5Z"
              clip-rule="evenodd"
            />
          </svg>
        </.link>
        <button
          :if={@count > 1}
          type="button"
          phx-click="nav"
          phx-value-dir="prev"
          class="focus-ring tap-target inline-flex items-center justify-center w-9 h-9 rounded-sm text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30"
          disabled={@idx == 0}
          aria-label="Previous"
        >
          ←
        </button>
        <button
          :if={@count > 1}
          type="button"
          phx-click="nav"
          phx-value-dir="next"
          class="focus-ring tap-target inline-flex items-center justify-center w-9 h-9 rounded-sm text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30"
          disabled={@idx == @count - 1}
          aria-label="Next"
        >
          →
        </button>
      </:nav>

      <:subject :if={@slide && @msg}>
        <FocusedView.subject
          project={@slide.project_name || "Operator"}
          workspace={@slide.workspace_name}
          state={:needs_you}
          context={subject_context(@slide, @msg)}
        />
      </:subject>

      <%!-- ONE decision per slide, unboxed — the FocusedView already names the
           subject, so the content is just the question itself. --%>
      <div :if={@q}>
        <LoopyardWeb.Components.StreamCard.band
          tone={(@msg.status == :pending && :needs_you) || :neutral}
          chrome={:desktop}
        >
          <%!-- No identity chip here: the FocusedView subject right above
    already names project · workspace large — once is enough. --%>
          <LoopyardWeb.Components.StreamCard.header
            state={:needs_you}
            label_class={
              (@msg.status == :pending && "text-orange-700 dark:text-orange-400") ||
                "text-zinc-500 dark:text-zinc-400"
            }
          >
            <:label>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                class="w-3.5 h-3.5"
              >
                <path
                  fill-rule="evenodd"
                  d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.93-9.412c-.44-.305-1.054-.305-1.494 0-.146.101-.27.245-.354.435a.75.75 0 0 1-1.372-.606c.18-.405.45-.74.819-.995 1.041-.722 2.486-.722 3.527 0 .54.375.94.94.94 1.626 0 .609-.314 1.07-.658 1.39-.124.115-.26.222-.387.32l-.10.078c-.179.139-.31.255-.404.385-.087.12-.12.222-.12.334a.75.75 0 0 1-1.5 0c0-.49.218-.884.47-1.226.21-.286.482-.502.679-.654l.078-.06c.139-.108.224-.18.286-.237.087-.08.108-.13.108-.27a.484.484 0 0 0-.298-.473ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
                  clip-rule="evenodd"
                />
              </svg>
              {(@msg.status == :pending && "Needs your input") || "Answered"}
            </:label>
          </LoopyardWeb.Components.StreamCard.header>
          <Cards.question_block msg={@msg} q={@q} chat_path={@slide.path} />
        </LoopyardWeb.Components.StreamCard.band>

        <%!-- The "open the chat" escape is now a BUTTON in the card's action
    row (question_block's chat_path), so the three moves — Skip, Chat,
    Answer — sit together instead of two buttons plus a sentence
    floating underneath. --%>
        <p
          :if={@slide.path && @msg.status == :pending}
          class="chat-meta text-zinc-400 dark:text-zinc-500 mt-4"
        >
          Options and "Other…" answer just this question.
        </p>
      </div>

      <div :if={is_nil(@q) && @msg && @msg.role == :question}>
        <Cards.question_card msg={@msg} />
      </div>

      <div :if={is_nil(@q) && @msg && @msg.role == :approval}>
        <Cards.approval_card msg={@msg} />
      </div>

      <div :if={is_nil(@q) && @msg && @msg.role == :secret_request}>
        <Cards.secret_card msg={@msg} />
      </div>

      <div :if={is_nil(@msg)} class="flex flex-col items-center justify-center gap-4 py-24">
        <p class="chat-sub text-zinc-400 dark:text-zinc-500">
          {(@history? && "No questions asked yet.") || "Nothing waiting on you."}
        </p>
        <.link
          :if={!@history?}
          navigate="/review/history"
          class="chat-sub font-medium text-violet-600 dark:text-violet-400 hover:underline"
        >
          Flip through past questions →
        </.link>
        <.link
          navigate="/operator"
          class="chat-sub font-medium text-violet-600 dark:text-violet-400 hover:underline"
        >
          ← Back to the operator
        </.link>
      </div>

      <div :if={@slide && @slide.path && is_nil(@q) && @msg} class="mt-4">
        <.link
          navigate={@slide.path}
          class="chat-meta text-violet-600 dark:text-violet-400 hover:underline"
        >
          Open in chat for context →
        </.link>
      </div>
    </FocusedView.layout>
    """
  end

  defp subject_context(%{agent_name: name, asked_at: %DateTime{} = at}, _msg)
       when is_binary(name) do
    "#{name} asked #{ago(at)}"
  end

  defp subject_context(_, _), do: nil

  defp ago(at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> "moments ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
