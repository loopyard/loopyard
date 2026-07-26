defmodule LoopyardWeb.ReviewLive do
  @moduledoc """
  `/review` — the question Reviewer (plans/question-review.md): answer
  everything waiting on you, back to back. ONE item per screen (question /
  approval / secret, the same live cards as the chat), prev/next, a position
  indicator, and answer-→-advance. Live: leave it open in a tab and new items
  join the queue as agents ask.

  Sourced from `Loopyard.Attention.line/0` (durable, card-sourced), so nothing
  waiting can be missing here. The current item is keyed by `{agent_id, msg_id}`
  so queue churn never yanks the screen out from under you.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.Events
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  @tick_ms 3_000
  @advance_ms 900

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    # Optional scope: /review?workspace=<id> reviews ONE workspace's line —
    # the same surface embeds per-workspace (Brad: any workspace can open its
    # own reviewer).
    scope = params["workspace"]
    socket = assign(socket, :scope, scope)
    items = line(scope)

    current =
      with q when is_binary(q) <- params["q"],
           [aid, mid] <- String.split(q, ":", parts: 2),
           %{} = item <- Enum.find(items, &(&1.agent_id == aid and &1.msg && &1.msg.id == mid)) do
        key(item)
      else
        _ -> items |> List.first() |> then(&(&1 && key(&1)))
      end

    {:ok,
     socket
     |> assign(:items, items)
     |> assign(:current, current)
     |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: scope)
     |> sync_secret_scope()}
  end

  defp key(item), do: {item.agent_id, item.msg && item.msg.id}

  defp line(scope \\ nil) do
    Loopyard.Attention.line()
    |> Enum.filter(&(is_nil(scope) or &1.workspace_id == scope))
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ── queue upkeep ─────────────────────────────────────────────────────────

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  # Any agent activity can settle or add items.
  def handle_info(%Events.Activity.Event{}, socket), do: {:noreply, refresh(socket)}

  # The settled beat is over — move to the next pending item.
  def handle_info(:advance, socket) do
    items = line(socket.assigns.scope)
    {:noreply,
     socket |> assign(:items, items) |> assign(:current, first_key(items)) |> sync_secret_scope()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp first_key(items), do: items |> List.first() |> then(&(&1 && key(&1)))

  # Refresh the queue. If the CURRENT item just resolved (left the line), hold
  # it on screen for a settled beat, then advance.
  defp refresh(socket) do
    items = line(socket.assigns.scope)
    cur = socket.assigns.current

    cond do
      is_nil(cur) ->
        socket |> assign(:items, items) |> assign(:current, first_key(items))

      Enum.any?(items, &(key(&1) == cur)) ->
        assign(socket, :items, items)

      true ->
        Process.send_after(self(), :advance, @advance_ms)
        assign(socket, :items, items)
    end
  end

  # ── navigation ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("nav", %{"dir" => dir}, socket) do
    items = socket.assigns.items
    idx = Enum.find_index(items, &(key(&1) == socket.assigns.current)) || 0
    n = length(items)

    next =
      case dir do
        "next" -> min(idx + 1, n - 1)
        _ -> max(idx - 1, 0)
      end

    {:noreply,
     socket
     |> assign(:current, items |> Enum.at(next) |> then(&(&1 && key(&1))))
     |> sync_secret_scope()}
  end

  def handle_event("decide_approval", %{"approval_id" => id, "decision" => decision}, socket) do
    decision = if decision == "approve", do: :approve, else: :deny

    case current_item(socket) do
      %{agent_id: aid} -> LoopyardWeb.Live.ApprovalActions.decide(aid, id, decision)
      _ -> :ok
    end

    {:noreply, socket}
  end

  defp current_item(socket),
    do: Enum.find(socket.assigns.items, &(key(&1) == socket.assigns.current))

  # Secrets submitted in the reviewer scope to the CURRENT item's workspace —
  # ConsentUI reads :consent_secret_scope from socket assigns at submit time.
  defp sync_secret_scope(socket) do
    assign(
      socket,
      :consent_secret_scope,
      case current_item(socket) do
        %{workspace_id: ws} -> ws
        _ -> socket.assigns[:scope]
      end
    )
  end

  # The LIVE message for the current item (fresh state every render — a click
  # anywhere flips it for every viewer).
  defp current_msg(nil), do: nil

  defp current_msg(%{agent_id: aid, msg: %{id: mid}}) do
    Loopyard.ChatAgent.get_message(aid, mid)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp current_msg(_), do: nil

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    item = Enum.find(assigns.items, &(key(&1) == assigns.current))
    idx = Enum.find_index(assigns.items, &(key(&1) == assigns.current))

    assigns =
      assigns
      |> assign(:item, item)
      |> assign(:msg, current_msg(item))
      |> assign(:idx, idx)
      |> assign(:count, length(assigns.items))

    ~H"""
    <div class="min-h-screen flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <%!-- Header: where you are in the line + prev/next. --%>
      <div class="flex-none flex items-center gap-3 h-14 px-4 md:px-6 border-b border-zinc-200 dark:border-zinc-800">
        <span class="chat-meta font-semibold uppercase tracking-wide text-orange-700 dark:text-orange-400">
          Review
        </span>
        <span :if={@count > 0} class="chat-meta tabular-nums text-zinc-500 dark:text-zinc-400">
          {(@idx || 0) + 1} of {@count}
        </span>
        <div class="flex-1"></div>
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
        <LoopyardWeb.Components.Common.mode_nav active={:operator} class="ml-2" />
      </div>

      <%!-- ONE item, centered at the reading measure — mobile and desktop. --%>
      <div class="flex-1 overflow-y-auto">
        <div :if={@msg} class="mx-auto w-full max-w-2xl px-4 md:px-6 py-6 md:py-10">
          <.review_card msg={@msg} />
          <div :if={@item} class="mt-4">
            <.link
              navigate={@item.path}
              class="chat-meta text-violet-600 dark:text-violet-400 hover:underline"
            >
              Open in chat for context →
            </.link>
          </div>
        </div>

        <div :if={is_nil(@msg)} class="h-full flex items-center justify-center py-24">
          <p class="chat-sub text-zinc-400 dark:text-zinc-500">Nothing waiting on you.</p>
        </div>
      </div>
    </div>
    """
  end

  defp review_card(%{msg: %{role: :question}} = assigns), do: Cards.question_card(assigns)
  defp review_card(%{msg: %{role: :approval}} = assigns), do: Cards.approval_card(assigns)
  defp review_card(%{msg: %{role: :secret_request}} = assigns), do: Cards.secret_card(assigns)
  defp review_card(assigns), do: ~H""
end
