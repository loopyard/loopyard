defmodule LoopyardWeb.SoundLive do
  @moduledoc """
  Full-page control for the ambient sound bed.

  Reached by tapping the header speaker (a live `navigate`, so the root-layout
  AmbientAudio engine — and the audio — never cut). On/off + volume command that
  engine over window events (the `SoundPanel` hook); picking a track calls
  `Aural.Channel.pick_track/2`, which CROSSFADES the same `activity` stream, so
  the track changes without a reconnect either. Go back and you land on whatever
  you were doing, still playing.
  """
  use LoopyardWeb, :live_view

  @channel "activity"

  # The baseline roster (mirrors the aural package's proven set). Kept here so a
  # track add is a one-line edit; the descriptions are the picker's subtitles.
  @tracks [
    {:serene, "Serene", "warm major-7 pads, slow breath rhythm"},
    {:nocturne, "Nocturne", "dark minor, deep bass, unhurried"},
    {:cascade, "Cascade", "rotating chord, gentle upward motion"},
    {:hum, "Hum", "brown-noise floor + sub-bass drone"},
    {:pink, "Pink", "1/f noise — a masker and sleep aid"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sound")
     |> assign(:tracks, @tracks)
     |> assign(:current_track, current_track())}
  end

  @impl true
  def handle_event("pick_track", %{"track" => track}, socket) do
    track_atom = String.to_existing_atom(track)
    Aural.Channel.pick_track(@channel, track_atom)
    {:noreply, assign(socket, :current_track, track_atom)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  # Current bed track for initial highlight; tolerate the channel not being up.
  defp current_track do
    Aural.Channel.state(@channel).track
  rescue
    _ -> :serene
  catch
    _, _ -> :serene
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <div class="flex-none flex items-center gap-1 h-14 px-2 border-b border-zinc-200 dark:border-zinc-700/80">
        <button
          type="button"
          onclick="history.back()"
          aria-label="Back"
          class="flex-none inline-flex items-center justify-center w-11 h-11 rounded-lg text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition-colors"
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
            <path
              fill-rule="evenodd"
              d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z"
              clip-rule="evenodd"
            />
          </svg>
        </button>
        <h1 class="text-base font-semibold">Sound</h1>
      </div>

      <div id="sound-panel" phx-hook="SoundPanel" class="flex-1 overflow-y-auto">
        <%!-- Playback: the big power button toggles the persistent engine; the
             state label + volume mirror it. --%>
        <div class="p-5 border-b border-zinc-200 dark:border-zinc-700/60">
          <div class="flex items-center gap-4">
            <button
              type="button"
              data-sound-power
              aria-label="Toggle sound"
              aria-pressed="false"
              class="flex-none w-16 h-16 rounded-full bg-zinc-200 dark:bg-zinc-700 flex items-center justify-center transition-colors"
            >
              <svg
                data-sound-icon="off"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-7 h-7"
              >
                <path d="M10 3.75a.75.75 0 0 0-1.264-.546L5.203 6.5H3.667A1.667 1.667 0 0 0 2 8.167v3.666A1.667 1.667 0 0 0 3.667 13.5h1.536l3.533 3.296A.75.75 0 0 0 10 16.25V3.75Z" />
                <path d="M14.78 7.72a.75.75 0 0 0-1.06 1.06L14.94 10l-1.22 1.22a.75.75 0 1 0 1.06 1.06L16 11.06l1.22 1.22a.75.75 0 1 0 1.06-1.06L17.06 10l1.22-1.22a.75.75 0 0 0-1.06-1.06L16 8.94l-1.22-1.22Z" />
              </svg>
              <svg
                data-sound-icon="on"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-7 h-7 hidden"
              >
                <path d="M10 3.75a.75.75 0 0 0-1.264-.546L5.203 6.5H3.667A1.667 1.667 0 0 0 2 8.167v3.666A1.667 1.667 0 0 0 3.667 13.5h1.536l3.533 3.296A.75.75 0 0 0 10 16.25V3.75Z" />
                <path d="M14.657 3.879a.75.75 0 0 0-1.06 1.06 7 7 0 0 1 0 9.9.75.75 0 0 0 1.06 1.061 8.5 8.5 0 0 0 0-12.021Z" />
                <path d="M12.182 6.354a.75.75 0 0 0-1.06 1.06 3.5 3.5 0 0 1 0 4.95.75.75 0 0 0 1.06 1.06 5 5 0 0 0 0-7.07Z" />
              </svg>
            </button>
            <div class="min-w-0">
              <div data-sound-state class="text-lg font-semibold">Muted</div>
              <div class="text-sm text-zinc-500 dark:text-zinc-400">
                Ambient bed — plays across the whole app
              </div>
            </div>
          </div>

          <div class="mt-6">
            <label
              for="sound-volume"
              class="block text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400 mb-2"
            >
              Volume
            </label>
            <input
              id="sound-volume"
              type="range"
              data-sound-volume
              min="0"
              max="1"
              step="0.05"
              class="w-full h-2 accent-violet-600"
            />
          </div>
        </div>

        <%!-- Tracks: tapping crossfades the live stream (~3s), so switching
             never cuts the audio. --%>
        <div class="p-3">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400 px-2 mb-1.5">
            Tracks
          </h2>
          <div class="space-y-1">
            <button
              :for={{id, name, desc} <- @tracks}
              type="button"
              phx-click="pick_track"
              phx-value-track={id}
              class={[
                "w-full flex items-center gap-3 px-3 min-h-[3.5rem] rounded-xl text-left transition-colors",
                if(@current_track == id,
                  do: "bg-violet-100 dark:bg-violet-500/15",
                  else:
                    "hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700/60"
                )
              ]}
            >
              <span class={[
                "flex-none w-2 h-2 rounded-full",
                if(@current_track == id, do: "bg-violet-500", else: "bg-zinc-300 dark:bg-zinc-600")
              ]}></span>
              <span class="flex-1 min-w-0">
                <span class="block font-medium text-zinc-900 dark:text-zinc-100">{name}</span>
                <span class="block text-sm text-zinc-500 dark:text-zinc-400 truncate">{desc}</span>
              </span>
              <svg
                :if={@current_track == id}
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-5 h-5 flex-none text-violet-600 dark:text-violet-400"
              >
                <path
                  fill-rule="evenodd"
                  d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
