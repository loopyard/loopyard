defmodule LoopyardWeb.QueueLive do
  @moduledoc """
  `/queue` — the **town hall**. Every agent that's blocked waiting on a human
  forms a line at the mic; you walk down the line answering one question after
  another, from every workspace at once, without hunting through each chat where
  the ask scrolled off-screen.

  A tear-out view by design (its own URL, no chrome to speak of) — pop it into a
  second window and just watch the line.

  The line is `Loopyard.Attention.line/1` (self-decaying: a question nobody
  answers inside its TTL ages out on its own). Questions are answered **inline**
  through the shared `LoopyardWeb.Live.ConsentUI` hook — the exact same handlers
  the workspace + operator chats use, which is what lets a question be cleared
  here even though it belongs to another agent's stream. Secrets and blocking
  approvals appear in the line as "open it where it lives" rows (their answer is
  workspace-scoped, so they resolve in the agent's own chat).
  """
  use LoopyardWeb, :live_view

  import LoopyardWeb.Live.WorkspaceLive.Messages.Cards, only: [question_card: 1]
  alias Loopyard.{Attention, Events}

  # Re-query cadence. Cheap (ETS scans), and it's also what advances the decay —
  # a timed-out question drops off within this window even with no broadcast.
  @tick_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    if connected?(socket) do
      # Any agent going quiet/awaiting anywhere → refresh the line.
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:host, host)
     |> assign(:page_title, "Town hall")
     |> refresh()
     # Questions answer through the shared consent hook. No workspace here, so
     # secrets aren't submitted inline (they're open-in-chat rows) — nil scope.
     |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: nil)}
  end

  defp refresh(socket) do
    line = Attention.line(socket.assigns.host)
    assign(socket, line: line, count: length(line))
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info(%Events.Activity.Event{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100">
      <div class="mx-auto max-w-3xl px-4 py-8 sm:py-12">
        <header class="mb-8 flex items-baseline justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Town hall</h1>
            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
              <%= if @count == 0 do %>
                The floor is clear — nobody's waiting on you.
              <% else %>
                {@count} {if @count == 1, do: "agent is", else: "agents are"} at the mic.
              <% end %>
            </p>
          </div>
          <.link
            navigate={~p"/operator"}
            class="focus-ring text-sm font-medium text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100"
          >
            ← Operator
          </.link>
        </header>

        <div :if={@count == 0} class="rounded-2xl border border-dashed border-zinc-300 dark:border-zinc-700 px-6 py-16 text-center">
          <div class="text-4xl">🎤</div>
          <p class="mt-3 text-sm text-zinc-500 dark:text-zinc-400">
            When an agent needs a decision, a secret, or an approval, it lines up here.
          </p>
        </div>

        <ol :if={@count > 0} class="flex flex-col gap-4">
          <li
            :for={item <- @line}
            id={"attn-#{item.kind}-#{item.id}"}
            class="overflow-hidden rounded-2xl border border-zinc-200 bg-white shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
          >
            <%!-- who's at the mic --%>
            <.link
              navigate={item.path}
              class="focus-ring flex items-center gap-2 border-b border-zinc-100 px-4 py-2.5 text-xs hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800/50"
            >
              <span class={["inline-block h-1.5 w-1.5 flex-none rounded-full", kind_dot(item.kind)]}></span>
              <span class="font-semibold text-zinc-700 dark:text-zinc-200">{item.agent_name}</span>
              <span class="text-zinc-400 dark:text-zinc-500">·</span>
              <span class="truncate text-zinc-500 dark:text-zinc-400">
                {item.workspace_name || "Operator"}
              </span>
              <span class="ml-auto flex-none text-zinc-400 group-hover:text-zinc-600 dark:text-zinc-500">
                open →
              </span>
            </.link>

            <%!-- QUESTIONS answer inline (shared consent hook). SECRETS/APPROVALS
                 resolve in their own chat — link with a one-line summary. --%>
            <div class="p-2 sm:p-3">
              <.question_card :if={item.kind == :question and item.msg} msg={item.msg} />
              <.link
                :if={item.kind != :question or is_nil(item.msg)}
                navigate={item.path}
                class="focus-ring flex items-center gap-3 rounded-xl px-3 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
              >
                <span class="text-sm text-zinc-700 dark:text-zinc-200">{item.label}</span>
                <span class="ml-auto text-xs font-medium text-amber-700 dark:text-amber-400">Open →</span>
              </.link>
            </div>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  defp kind_dot(:question), do: "bg-amber-500"
  defp kind_dot(:secret), do: "bg-sky-500"
  defp kind_dot(:approval), do: "bg-violet-500"
  defp kind_dot(_), do: "bg-zinc-400"
end
