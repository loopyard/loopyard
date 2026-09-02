defmodule LoopyardWeb.ActivitySound do
  @moduledoc """
  The sound bridge: activity + inbox → the ambient bed's LEVEL and its
  CHIMES. A pure **subscriber** of `Loopyard.Events.Activity` and
  `Loopyard.Events.Notifications`; the core never learns it exists — delete
  this module + `packages/aural` and Loopyard is unchanged (the sound
  boundary test enforces it). Lives at the web edge precisely because it
  references `Aural`, which the core is forbidden to.

  ## The level — how busy the machine is
  The bed swells with the FLEET: the level follows how many agents are
  thinking right now (`level_for/1`), page-independent — it used to be the
  operator's own status, computed in the operator page, so it only moved while
  someone had `/operator` open.

  ## The chimes — three moments, three voices
  * `"done"` — a turn finished with something to say (`:turn_end`).
  * `"attention"` — a human is needed: a decision raised on the inbox (a
    question, an approval, a secret request — all three; only questions
    used to ring).
  * `"alert"` — something broke (rate-limited, auth expired, crashed).
  In-progress transitions are silent; chiming when a turn STARTS was the
  annoying beep.

  ## Channels & proximity
  Each chime fires on the global `"activity"` channel and the item's
  per-project `"project-<id>"` channel, so a viewer can mix near loud and far
  soft. The server just fires on both.
  """
  use GenServer

  alias Loopyard.Events
  alias Loopyard.Notifications.Item

  @global_channel "activity"
  @idle_level 0.12
  @busy_level 0.7
  # Three agents thinking is "the shop is humming"; more doesn't get louder.
  @full_at 3

  def start_link(_opts) do
    # Gated by config so tests (and anyone who wants silence) don't spin up
    # ffmpeg/mp3 encoders. Default on for dev/prod; off in test.
    if Application.get_env(:loopyard, :activity_sound, true) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(:ok) do
    Events.Activity.subscribe_global()
    Events.Notifications.subscribe()
    {:ok, %{thinking: MapSet.new()}}
  end

  @impl true
  def handle_info(%Events.Activity.Event{kind: :status} = e, state) do
    state = track_busy(state, e)
    Aural.Channel.set_activity(@global_channel, level_for(MapSet.size(state.thinking)))
    fire(chime_for(e), e.project_id)
    {:noreply, state}
  rescue
    # Sound is decorative — never let it disturb anything.
    _ -> {:noreply, state}
  catch
    _, _ -> {:noreply, state}
  end

  def handle_info(%Events.Activity.Event{kind: :turn_end} = e, state) do
    fire(chime_for(e), e.project_id)
    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  catch
    _, _ -> {:noreply, state}
  end

  def handle_info(%Events.Notifications.Added{item: %Item{} = item}, state) do
    fire(chime_for(item), item.project_id)
    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  catch
    _, _ -> {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Per-project channel id for a project (sanitized to the Aural id charset)."
  def project_channel(project_id), do: "project-#{sanitize(project_id)}"

  @doc "The bed level for N agents thinking: idle floor to a full hum at #{@full_at}."
  @spec level_for(non_neg_integer()) :: float()
  def level_for(n) when is_integer(n) and n >= 0,
    do: @idle_level + (@busy_level - @idle_level) * min(n, @full_at) / @full_at

  @doc """
  Which chime an event earns — `"done"`, `"attention"`, `"alert"` — or nil
  for silence.
  """
  @spec chime_for(term()) :: String.t() | nil
  def chime_for(%Events.Activity.Event{kind: :status, summary: s})
      when s in ["rate_limited", "auth_expired", "crashed"],
      do: "alert"

  def chime_for(%Events.Activity.Event{kind: :turn_end, workspace_id: ws, summary: s})
      when is_binary(ws) and is_binary(s) and s != "",
      do: "done"

  def chime_for(%Item{kind: k}) when k in [:question, :approval, :secret], do: "attention"
  def chime_for(_), do: nil

  defp track_busy(state, %{agent_id: aid, summary: s})
       when s in ["thinking", "backoff", "compacting"],
       do: %{state | thinking: MapSet.put(state.thinking, aid)}

  defp track_busy(state, %{agent_id: aid}),
    do: %{state | thinking: MapSet.delete(state.thinking, aid)}

  defp fire(nil, _project_id), do: :ok

  defp fire(kind, project_id) do
    Aural.Channel.fire(@global_channel, kind)
    if project_id, do: Aural.Channel.fire(project_channel(project_id), kind)
    :ok
  end

  defp sanitize(id), do: id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "")
end
