defmodule Loopyard.Notifications.Push do
  @moduledoc """
  Web Push from the INBOX, not from the tool call sites. Subscribes to
  `Events.Notifications` and pushes every raised item to the devices that
  asked for its kind: decisions (a question / approval / secret request — the
  default), and, opt-in per device, finished turns. `Harness.Questions` used
  to push on its own, so only questions ever reached a pocket; approvals and
  secrets were silent.

  The URL is the item's own slide (`/notifications/:agent/:msg`), so a tap
  lands ON it. One push per item: a finished item replaced by the next turn
  (a `Changed`, not an `Added`) does not push again, and a fresh finished
  item for the same agent within `@finished_cooldown_ms` is skipped too.
  """
  use GenServer
  require Logger

  alias Loopyard.Events
  alias Loopyard.Notifications.Item

  @finished_cooldown_ms 10 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.Notifications.subscribe()
    {:ok, %{last_finished: %{}}}
  end

  @impl true
  def handle_info(%Events.Notifications.Added{item: %Item{} = item}, state) do
    {:noreply, maybe_push(item, state)}
  rescue
    e ->
      Logger.warning("[Notifications.Push] failed: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_push(%Item{kind: :finished, agent_id: aid} = item, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.last_finished, aid) do
      t when is_integer(t) and now - t < @finished_cooldown_ms ->
        state

      _ ->
        Loopyard.WebPush.notify(:finished, title(item), item.label, url(item))
        %{state | last_finished: Map.put(state.last_finished, aid, now)}
    end
  end

  defp maybe_push(%Item{} = item, state) do
    Loopyard.WebPush.notify(:decision, title(item), item.label, url(item))
    state
  end

  @doc "The push title: what kind of thing, and where from."
  def title(%Item{kind: :finished} = item), do: "Finished — " <> where(item)
  def title(%Item{kind: :approval} = item), do: "Approval — " <> where(item)
  def title(%Item{kind: :secret} = item), do: "Secret needed — " <> where(item)
  def title(%Item{} = item), do: "Decision — " <> where(item)

  @doc "The item's slide."
  def url(%Item{agent_id: aid, msg_id: mid}),
    do: "/notifications/#{aid}/#{mid || "fin"}"

  defp where(%Item{project_name: p, workspace_name: w}) when is_binary(p) and is_binary(w),
    do: "#{p} · #{w}"

  defp where(%Item{agent_name: a}) when is_binary(a), do: a
  defp where(_), do: "Loopyard"
end
