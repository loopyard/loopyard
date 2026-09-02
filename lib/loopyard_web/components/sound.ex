defmodule LoopyardWeb.Components.Sound do
  @moduledoc """
  The soundtrack's always-there control — the little player that rides in
  every top bar next to the altitude control, so the ambient bed is a thing
  you can reach from anywhere, not a page you visit.

  Phone: a play/pause button and a settings link (the `/sound` page, where
  the tracks are). Desktop: play/pause, the current track's name (also the
  way to `/sound`) and a volume slider. One component, one hook (`SoundPill`,
  which drives the root-layout `AmbientAudio` engine over window events and
  mirrors its state back), so the engine never restarts as you navigate.
  """
  use Phoenix.Component

  alias LoopyardWeb.SoundLive

  attr :id, :string, required: true, doc: "unique per placement (the hook needs it)"
  attr :class, :string, default: nil

  def pill(assigns) do
    assigns = assign(assigns, :track_name, current_track_name())

    ~H"""
    <div
      id={@id}
      phx-hook="SoundPill"
      data-on="text-violet-600 dark:text-violet-400"
      data-off="text-zinc-500 dark:text-zinc-400"
      class={["flex items-center gap-0.5 md:gap-2 text-zinc-500 dark:text-zinc-400", @class]}
    >
      <button
        type="button"
        data-sound-power
        aria-label="Play or pause the soundtrack"
        title="Play / pause the soundtrack"
        class="focus-ring flex-none inline-flex items-center justify-center w-11 h-11 md:w-9 md:h-9 rounded-full hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
      >
        <%!-- OFF (paused) → PLAY glyph; ON (playing) → PAUSE glyph. --%>
        <svg data-sound-icon="off" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
          <path d="M6.3 2.84A1 1 0 0 0 5 3.79v12.42a1 1 0 0 0 1.55.83l9.06-6.21a1 1 0 0 0 0-1.66L6.3 2.84Z" />
        </svg>
        <svg data-sound-icon="on" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 hidden">
          <path d="M6 3.5A1.5 1.5 0 0 0 4.5 5v10a1.5 1.5 0 0 0 3 0V5A1.5 1.5 0 0 0 6 3.5Zm8 0A1.5 1.5 0 0 0 12.5 5v10a1.5 1.5 0 0 0 3 0V5A1.5 1.5 0 0 0 14 3.5Z" />
        </svg>
      </button>

      <%!-- Desktop: the track's name is the way to change it. --%>
      <.link
        navigate="/sound"
        title="Change the track"
        class="focus-ring hidden md:inline-flex items-center gap-1 max-w-32 rounded-sm px-1 py-0.5 text-meta font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
      >
        <span class="truncate">{@track_name}</span>
        <svg viewBox="0 0 20 20" fill="currentColor" class="w-3.5 h-3.5 flex-none opacity-60">
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
        class="volume-slider hidden md:block w-20"
      />

      <%!-- Phone: no room for a name or a slider — one tap to the sound page. --%>
      <.link
        navigate="/sound"
        aria-label="Sound settings"
        title="Sound — tracks and volume"
        class="focus-ring md:hidden flex-none inline-flex items-center justify-center w-11 h-11 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
      >
        <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5" aria-hidden="true">
          <path d="M3 4.5a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 3 4.5Zm10.25-.75a.75.75 0 0 0 0 1.5h3a.75.75 0 0 0 0-1.5h-3ZM3 10a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5A.75.75 0 0 1 3 10Zm6.25-.75a.75.75 0 0 0 0 1.5h7a.75.75 0 0 0 0-1.5h-7ZM3 15.5a.75.75 0 0 1 .75-.75h8.5a.75.75 0 0 1 0 1.5h-8.5a.75.75 0 0 1-.75-.75Zm12.25-.75a.75.75 0 0 0 0 1.5h1a.75.75 0 0 0 0-1.5h-1Z" />
        </svg>
      </.link>
    </div>
    """
  end

  # The bed's current track, by name — tolerating the channel not being up.
  defp current_track_name do
    SoundLive.track_name(Aural.Channel.state("activity").track)
  rescue
    _ -> "Sound"
  catch
    _, _ -> "Sound"
  end
end
