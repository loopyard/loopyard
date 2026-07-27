defmodule LoopyardWeb.OperatorLive.Rail do
  @moduledoc """
  The `/operator` "for you" rail — the render function-components (needs-you
  groups, working jobs, wrapped buckets, the docked sound player) plus the
  pure data-shaping helpers (`fade_class/2`, `bucket_done/2`) that
  `OperatorLive.refresh_rail/1` uses to build the rail's assigns. Split out
  of `LoopyardWeb.OperatorLive` to keep that file under its size cap;
  `refresh_rail/1` itself stays in the LiveView (it assigns).
  """
  use LoopyardWeb, :html

  @doc """
  Opacity by how long since the workspace was last active. Recent work stays
  bright; older work dims and recedes. Floored at 50% so a faded row is still
  readable WITHOUT hover (mobile has none) — hover/tap restores full weight.
  This makes recency visual, not just the sort order.
  """
  def fade_class(%DateTime{} = at, now) do
    case DateTime.diff(now, at, :minute) do
      m when m < 10 -> "opacity-100"
      m when m < 60 -> "opacity-75"
      m when m < 360 -> "opacity-60"
      _ -> "opacity-50"
    end
  end

  def fade_class(_, _), do: "opacity-50"

  # Recency GROUPS instead of a fade: readable at any age, and recency reads from
  # the section label ("Recently" / "Past hour" / "Today" / "Earlier"), not from
  # dimming rows to near-invisible. Returns a list of {label, items}, non-empty
  # groups only, in newest→oldest order.
  @recency_order [
    {:recently, "Recently"},
    {:hour, "Past hour"},
    {:day, "Today"},
    {:older, "Earlier"}
  ]

  def bucket_done(done, now) do
    by = Enum.group_by(done, &recency_bucket(&1[:last_activity_at], now))

    for {key, label} <- @recency_order,
        items = Map.get(by, key, []),
        items != [],
        do: {label, items}
  end

  defp recency_bucket(%DateTime{} = at, now) do
    case DateTime.diff(now, at, :minute) do
      m when m < 15 -> :recently
      m when m < 60 -> :hour
      m when m < 1440 -> :day
      _ -> :older
    end
  end

  defp recency_bucket(_, _), do: :older

  # The "for you" rail — PURE render of assigns computed in refresh_rail/1 (bound
  # to the reactive graph, so it updates when a question is answered). NEEDS YOU
  # (blocking items, grouped by workspace, answered inline via the ConsentUI hook)
  # + WORKING (dispatched jobs, live state + delta).
  attr :operator_attention, :list, default: []
  attr :attention_by_ws, :map, default: %{}
  attr :groups, :list, required: true
  attr :active, :list, required: true
  attr :done_buckets, :list, required: true
  attr :vapid_key, :string, default: nil

  # One-line gist for a rail row: the first question's prompt (or the secret's
  # name) — enough to recognize, not the whole card.
  defp attention_summary(%{kind: :question, msg: %{questions: [q | _]}}), do: q.prompt
  defp attention_summary(%{kind: :secret, msg: %{name: name}}), do: "Needs a secret: #{name}"
  defp attention_summary(item), do: item[:label] || "Needs your input"

  def for_you_rail(assigns) do
    ~H"""
    <div class="flex flex-col">
      <%!-- The OPERATOR's own questions — no workspace row to nest under, so
           they lead the rail. Same flame mini-language; tap → the Reviewer. --%>
      <section :if={@operator_attention != []} class="p-3 pb-0">
        <div class="text-[11px] font-medium uppercase tracking-wide text-orange-700/80 dark:text-orange-400/80 px-1 pb-1">
          Operator · needs you
        </div>
        <div class="space-y-0.5">
          <.link
            :for={item <- @operator_attention}
            navigate={(item.msg && "/review/#{item.agent_id}/#{item.msg.id}") || "/review"}
            class="flex items-center gap-2.5 rounded-sm px-2 py-2 lg:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
          >
            <svg
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 flex-none text-orange-600 dark:text-orange-400"
              aria-hidden="true"
            ><path
              fill-rule="evenodd"
              d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.93-9.412c-.44-.305-1.054-.305-1.494 0-.146.101-.27.245-.354.435a.75.75 0 0 1-1.372-.606c.18-.405.45-.74.819-.995 1.041-.722 2.486-.722 3.527 0 .54.375.94.94.94 1.626 0 .609-.314 1.07-.658 1.39-.124.115-.26.222-.387.32l-.10.078c-.179.139-.31.255-.404.385-.087.12-.12.222-.12.334a.75.75 0 0 1-1.5 0c0-.49.218-.884.47-1.226.21-.286.482-.502.679-.654l.078-.06c.139-.108.224-.18.286-.237.087-.08.108-.13.108-.27a.484.484 0 0 0-.298-.473ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
              clip-rule="evenodd"
            /></svg>
            <span class="flex-1 min-w-0 truncate chat-meta text-zinc-700 dark:text-zinc-200">
              {attention_summary(item)}
            </span>
          </.link>
        </div>
      </section>

      <%!-- IN MOTION — what's actually RUNNING right now, prominent. Delta sits
    INLINE next to the name (not floated across the rail), so it reads as
    one line. The row taps through to the workspace agent (the weeds). --%>
      <section class="p-3 border-t border-zinc-200 dark:border-zinc-800">
        <div class="text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500 px-1 pb-1.5">
          In motion
        </div>
        <p :if={@active == []} class="px-1 py-1 text-sm text-zinc-500 dark:text-zinc-400">
          Nothing running right now.
        </p>
        <div :for={i <- @active}>
          <div
            phx-click="open_job"
            phx-value-ws={i.id}
            phx-value-project={i.project_id}
            phx-value-agent={i.agent_id}
            title={"#{i.project_name} · #{i.workspace_name} — #{state_label(i.state)}"}
            class="group flex items-center gap-2.5 rounded-sm px-2.5 py-3 lg:py-1.5 cursor-pointer hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
          >
            <.workspace_identity
              project={i.project_name}
              workspace={i.workspace_name}
              state={(i.state == :chugging && :working) || i.state}
              class="flex-1"
            />
            <span
              :if={i.delta > 0}
              title={"#{i.delta} new since you last looked"}
              class="flex-none text-xs font-semibold text-violet-600 dark:text-violet-400 tabular-nums"
            >
              {i.delta} new
            </span>
            <span class="ml-auto flex-none text-xs font-medium text-violet-600 dark:text-violet-400 opacity-0 group-hover:opacity-100 transition-opacity">
              dive in →
            </span>
          </div>
          <%!-- The workspace's OPEN QUESTIONS, nested right under its row — the
             flame mini-language (the question's own words). Tap → the Reviewer
             at that item. Capped at 3; the rest are one tap away. --%>
          <div :if={Map.get(@attention_by_ws, i.id, []) != []} class="pl-4 pb-1 space-y-0.5">
            <.link
              :for={item <- Enum.take(Map.get(@attention_by_ws, i.id, []), 3)}
              navigate={
                (item.msg && "/review/#{item.agent_id}/#{item.msg.id}") ||
                  "/projects/#{i.project_id}/workspaces/#{i.id}/review"
              }
              class="flex items-center gap-2.5 rounded-sm px-2 py-2 lg:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
            >
              <svg
                viewBox="0 0 16 16"
                fill="currentColor"
                class="w-3.5 h-3.5 flex-none text-orange-600 dark:text-orange-400"
                aria-hidden="true"
              ><path
                fill-rule="evenodd"
                d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.93-9.412c-.44-.305-1.054-.305-1.494 0-.146.101-.27.245-.354.435a.75.75 0 0 1-1.372-.606c.18-.405.45-.74.819-.995 1.041-.722 2.486-.722 3.527 0 .54.375.94.94.94 1.626 0 .609-.314 1.07-.658 1.39-.124.115-.26.222-.387.32l-.10.078c-.179.139-.31.255-.404.385-.087.12-.12.222-.12.334a.75.75 0 0 1-1.5 0c0-.49.218-.884.47-1.226.21-.286.482-.502.679-.654l.078-.06c.139-.108.224-.18.286-.237.087-.08.108-.13.108-.27a.484.484 0 0 0-.298-.473ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
                clip-rule="evenodd"
              /></svg>
              <span class="flex-1 min-w-0 truncate chat-meta text-zinc-700 dark:text-zinc-200">
                {attention_summary(item)}
              </span>
            </.link>
            <.link
              :if={length(Map.get(@attention_by_ws, i.id, [])) > 3}
              navigate={"/projects/#{i.project_id}/workspaces/#{i.id}/review"}
              class="block pl-2.5 chat-meta text-orange-700 dark:text-orange-400 hover:underline"
            >
              +{length(Map.get(@attention_by_ws, i.id, [])) - 3} more →
            </.link>
          </div>
        </div>

        <%!-- WRAPPED work, grouped by how long ago (Recently / Past hour / Today
    / Earlier). Full size + full opacity at every age — recency reads
    from the section label, not from dimming rows away. --%>
        <div :for={{label, items} <- @done_buckets} class="mt-3">
          <div class="text-[11px] font-medium uppercase tracking-wide text-zinc-400/80 dark:text-zinc-600 px-1 pb-1">
            {label}
          </div>
          <div
            :for={i <- items}
            phx-click="open_job"
            phx-value-ws={i.id}
            phx-value-project={i.project_id}
            phx-value-agent={i.agent_id}
            title={"#{i.project_name} · #{i.workspace_name} — done"}
            class="group flex items-center gap-2 rounded-sm px-2.5 py-3 lg:py-1.5 cursor-pointer hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
          >
            <.workspace_identity
              project={i.project_name}
              workspace={i.workspace_name}
              state={:done}
              size={:md}
              class="flex-1"
            />
            <span class="ml-auto flex-none text-[11px] font-medium text-violet-500 opacity-0 group-hover:opacity-100 transition-opacity">
              →
            </span>
          </div>
        </div>
        <%!-- Question push notifications: subscribe THIS device (installed
             PWA). The PushBell hook owns permission + subscription state
             client-side; the server only stores/deletes subscriptions. --%>
        <button
          type="button"
          id="push-bell"
          phx-hook="PushBell"
          data-vapid={@vapid_key}
          class="mt-4 flex items-center gap-2 -mx-1 px-1 py-2 chat-meta text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
        >
          <span data-bell-label>Notify me about questions</span>
        </button>
        <%!-- Workstations — the operator's own identities/creds live in this
             mode (plans/ia-two-modes.md). A quiet footer destination. --%>
        <.link
          navigate="/workstations"
          class="mt-4 flex items-center gap-2 -mx-1 px-1 py-2 chat-meta text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
        >
          Workstations →
        </.link>
      </section>
    </div>
    """
  end

  # Docked ambient-sound player. Reuses the SoundPill hook (drives the root-layout
  # AmbientAudio engine over window events) for play/pause + volume; the track
  # pills crossfade the bed via `pick_track` (server). Bigger than the old header
  # pill: play button, track name, volume, and the roster to switch.
  attr :id, :string, required: true
  attr :tracks, :list, required: true
  attr :current_track, :atom, required: true

  def sound_player(assigns) do
    assigns =
      assign(
        assigns,
        :track_name,
        Enum.find_value(assigns.tracks, "Sound", fn {id, name} ->
          id == assigns.current_track && name
        end)
      )

    ~H"""
    <div class="flex-none border-t border-zinc-200 dark:border-zinc-800 p-3 bg-zinc-50/60 dark:bg-zinc-900/40">
      <div
        id={@id}
        phx-hook="SoundPill"
        data-on="text-violet-600 dark:text-violet-400"
        data-off="text-zinc-400 dark:text-zinc-500"
        class="text-zinc-400 dark:text-zinc-500"
      >
        <div class="flex items-center gap-3">
          <button
            type="button"
            data-sound-power
            aria-label="Play or pause the ambient sound"
            title="Play / pause"
            class="focus-ring flex-none inline-flex items-center justify-center w-10 h-10 rounded-full bg-white dark:bg-zinc-800 border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-50 dark:hover:bg-zinc-700 transition-colors"
          >
            <%!-- OFF (paused) → PLAY --%>
            <svg data-sound-icon="off" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
              <path d="M6.3 2.84A1 1 0 0 0 5 3.79v12.42a1 1 0 0 0 1.55.83l9.06-6.21a1 1 0 0 0 0-1.66L6.3 2.84Z" />
            </svg>
            <%!-- ON (playing) → PAUSE --%>
            <svg data-sound-icon="on" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 hidden">
              <path d="M6 3.5A1.5 1.5 0 0 0 4.5 5v10a1.5 1.5 0 0 0 3 0V5A1.5 1.5 0 0 0 6 3.5Zm8 0A1.5 1.5 0 0 0 12.5 5v10a1.5 1.5 0 0 0 3 0V5A1.5 1.5 0 0 0 14 3.5Z" />
            </svg>
          </button>

          <div class="flex-1 min-w-0">
            <%!-- Track name is the "change it" affordance: tap → the full /sound
    UI (picker). The chevron signals it's tappable. --%>
            <.link
              navigate={~p"/sound"}
              title="Change the track"
              class="focus-ring group -mx-1 inline-flex max-w-full items-center gap-1 rounded-sm px-1 py-0.5 hover:bg-zinc-200/60 dark:hover:bg-zinc-700/60 transition-colors"
            >
              <span class="text-sm font-medium text-zinc-700 dark:text-zinc-200 truncate">
                {@track_name}
              </span>
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3.5 h-3.5 flex-none text-zinc-400 group-hover:text-zinc-600 dark:group-hover:text-zinc-300"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z"
                  clip-rule="evenodd"
                />
              </svg>
            </.link>
            <input
              type="range"
              min="0"
              max="1"
              step="0.01"
              data-sound-volume
              aria-label="Volume"
              class="volume-slider mt-1"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp state_label(:needs_you), do: "needs you"
  defp state_label(:done), do: "done"
  defp state_label(:chugging), do: "working"
  defp state_label(_), do: ""
end
