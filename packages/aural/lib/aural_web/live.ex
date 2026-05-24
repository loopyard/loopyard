defmodule AuralWeb.Live do
  @moduledoc """
  Listening page for the Aural feature (an ambient soundtrack driven by system state). Audio served as
  streaming MP3 from `AuralStreamController` (which subscribes
  to `Aural.Channel`'s PubSub topic and forwards bytes
  to the browser). Played by a native `<audio>` element. JS hook
  toggles play/pause and taps the audio output for an SVG
  oscilloscope. Track switches happen server-side on the shared
  channel, so the audio URL is stable across selections.

  Visual language is small caps section headers, mono readouts,
  zinc palette, restrained violet accent. The audio is an
  instrument, not a media player.

  Mount-time options (via session map):
    * `back_path` (string, default `"/"`) — where the small "← Back"
      link returns to. Host can route this to wherever Aural is
      surfaced from.
    * `back_label` (string, default `"Back"`) — label for that link.

  Tailwind classes used here must be in the host's tailwind content
  paths; see the package README.
  """
  use Phoenix.LiveView, layout: false

  alias Aural.LiveView, as: AuralLV
  alias Aural.Components

  # Each tuple: {atom, display name, one-line description, category}.
  # `:baseline` tracks are the proven roster designed to sit under
  # a future audio-signaling layer. `:experimental` ones are
  # research-adjacent and shown in a demoted section.
  @tracks [
    {:serene, "Serene", "warm major7 pads, 0.1Hz breath rhythm", :baseline},
    {:nocturne, "Nocturne", "dark minor, slow, deep bass", :baseline},
    {:cascade, "Cascade", "rotating chord, gentle upward motion", :baseline},
    {:hum, "Hum", "brown-noise masking floor + sub-bass drone", :baseline},
    {:gamma, "Gamma", "Serene + 40Hz amplitude entrainment", :experimental}
  ]

  @impl true
  def mount(%{"channel_id" => channel_id}, session, socket) do
    # AuralLV.subscribe wires us to the channel's alert + peak
    # topics and assigns :aural_channel so the event helpers can
    # find it. The MP3 byte stream goes to HTTP listeners via the
    # controller, not over this WS.
    {:ok,
     socket
     |> assign(:page_title, "Aural")
     |> assign(:tracks, @tracks)
     |> assign(:current_track, :serene)
     |> assign(:activity, "0.0")
     |> assign(:back_path, Map.get(session || %{}, "back_path", "/"))
     |> assign(:back_label, Map.get(session || %{}, "back_label", "Back"))
     |> AuralLV.subscribe(channel_id)}
  end

  @impl true
  def handle_info({:alert, _} = msg, socket), do: AuralLV.on_alert(msg, socket)
  def handle_info({:peak, _} = msg, socket), do: AuralLV.on_peak(msg, socket)

  @impl true
  def handle_event("pick_track", %{"track" => track}, socket),
    do: AuralLV.pick_track(socket, track)

  def handle_event("set_activity", %{"level" => level}, socket),
    do: AuralLV.set_activity(socket, level)

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:baseline_tracks, Enum.filter(@tracks, fn {_, _, _, c} -> c == :baseline end))
      |> assign(
        :experimental_tracks,
        Enum.filter(@tracks, fn {_, _, _, c} -> c == :experimental end)
      )

    ~H"""
    <div
      id="aural-page"
      phx-hook="Aural"
      class="min-h-screen bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 selection:bg-violet-500/20"
    >
      <Components.audio_elements channel_id={@aural_channel} />

      <main class="mx-auto max-w-2xl px-6 py-10 md:py-16">
        <header class="mb-10">
          <.link
            navigate={@back_path}
            class="text-[10px] font-mono uppercase tracking-widest text-zinc-500 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors focus-ring"
          >
            ← {@back_label}
          </.link>
          <div class="mt-4 flex items-baseline justify-between gap-4">
            <h1 class="text-base font-semibold tracking-tight">Aural</h1>
            <span class="text-[10px] font-mono uppercase tracking-widest text-zinc-400 dark:text-zinc-600">
              Experimental
            </span>
          </div>
          <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">
            Sustained beds designed as a cerebral baseline beneath a future signaling
            layer — gentle alerts for things needing a human's attention. No transients,
            no rhythm, mid-range only.
          </p>
        </header>

        <section class="border border-zinc-200 dark:border-zinc-800 rounded overflow-hidden">
          <div class="flex items-center justify-between gap-4 px-3 py-2 border-b border-zinc-200 dark:border-zinc-800 text-[10px] font-mono uppercase tracking-widest text-zinc-500 dark:text-zinc-500">
            <div class="flex items-baseline gap-2">
              <span>Output</span>
              <span aria-hidden="true" class="text-zinc-300 dark:text-zinc-700">/</span>
              <span id="aural-status" class="text-zinc-700 dark:text-zinc-300 normal-case tracking-normal">
                Click a track to play
              </span>
            </div>
            <span class="text-zinc-400 dark:text-zinc-600 hidden sm:inline">
              {@current_track} · mp3 · 128k · mono
            </span>
            <span class="text-zinc-400 dark:text-zinc-600 sm:hidden">{@current_track}</span>
          </div>

          <div class="px-4 pt-5 pb-4 bg-white dark:bg-zinc-900">
            <svg
              id="aural-scope"
              viewBox="0 0 800 120"
              preserveAspectRatio="none"
              class="w-full h-32 text-violet-500 dark:text-violet-400"
              aria-hidden="true"
            >
              <polyline
                id="aural-scope-line"
                points="0,60 800,60"
                fill="none"
                stroke="currentColor"
                stroke-width="1.2"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          </div>

          <button
            id="aural-toggle"
            type="button"
            aria-label="Play / pause"
            class="w-full flex items-center justify-center gap-3 px-4 py-4 border-t border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/50 hover:bg-zinc-100 dark:hover:bg-zinc-800/70 active:bg-zinc-200 dark:active:bg-zinc-800 transition-colors focus-ring text-zinc-900 dark:text-zinc-100"
          >
            <svg
              id="aural-icon-play"
              class="w-5 h-5 ml-0.5"
              viewBox="0 0 24 24"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M8 5v14l11-7z" />
            </svg>
            <svg
              id="aural-icon-pause"
              class="w-5 h-5 hidden"
              viewBox="0 0 24 24"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M6 4h4v16H6zM14 4h4v16h-4z" />
            </svg>
            <span
              id="aural-toggle-label"
              class="text-sm font-mono uppercase tracking-widest"
            >Play</span>
          </button>
        </section>

        <section class="mt-10">
          <h2 class="text-[10px] font-mono uppercase tracking-widest text-zinc-500 dark:text-zinc-500 mb-3">
            Bed
          </h2>
          <ul class="border-y border-zinc-200 dark:border-zinc-800 divide-y divide-zinc-200 dark:divide-zinc-800">
            <%= for {key, name, desc, _} <- @baseline_tracks do %>
              <li>
                <button
                  type="button"
                  phx-click="pick_track"
                  phx-value-track={key}
                  class={track_row_classes(@current_track == key)}
                >
                  <span aria-hidden="true" class={track_indicator_classes(@current_track == key)}>
                  </span>
                  <span class="font-mono text-sm tabular-nums w-24 shrink-0">{name}</span>
                  <span class="text-sm text-zinc-500 dark:text-zinc-400 leading-snug">{desc}</span>
                </button>
              </li>
            <% end %>
          </ul>
        </section>

        <section class="mt-10">
          <h2 class="flex items-center gap-3 text-[10px] font-mono uppercase tracking-widest text-zinc-400 dark:text-zinc-600 mb-3">
            <span>Experimental</span>
            <span aria-hidden="true" class="flex-1 h-px bg-zinc-200 dark:bg-zinc-800"></span>
          </h2>
          <ul class="border-y border-zinc-200 dark:border-zinc-800 divide-y divide-zinc-200 dark:divide-zinc-800">
            <%= for {key, name, desc, _} <- @experimental_tracks do %>
              <li>
                <button
                  type="button"
                  phx-click="pick_track"
                  phx-value-track={key}
                  class={track_row_classes(@current_track == key)}
                >
                  <span aria-hidden="true" class={track_indicator_classes(@current_track == key)}>
                  </span>
                  <span class="font-mono text-sm w-24 shrink-0">{name}</span>
                  <span class="text-sm text-zinc-500 dark:text-zinc-400 leading-snug">{desc}</span>
                </button>
              </li>
            <% end %>
          </ul>
          <p class="mt-3 text-xs text-zinc-400 dark:text-zinc-600 leading-relaxed">
            Research-adjacent. Effects on human cognition are preliminary, not proven.
          </p>
        </section>

        <section class="mt-12">
          <h2 class="flex items-center gap-3 text-[10px] font-mono uppercase tracking-widest text-zinc-400 dark:text-zinc-600 mb-3">
            <span>Signal Layer (sketch)</span>
            <span aria-hidden="true" class="flex-1 h-px bg-zinc-200 dark:bg-zinc-800"></span>
          </h2>
          <p class="text-xs text-zinc-500 dark:text-zinc-500 leading-relaxed mb-4">
            What if events surfaced as gentle tones mixed into the bed? Chimes fire
            once and decay; activity level rides on top of whatever's playing,
            boosting the pad's pad gain so "busy" reads as "richer." Global for
            now — every listener hears the same signals.
          </p>

          <div class="space-y-4">
            <div>
              <div class="text-[10px] font-mono uppercase tracking-widest text-zinc-500 mb-2">
                Chimes
              </div>
              <div class="flex flex-wrap gap-2">
                <%!--
                  Chime buttons are JS-only — the hook catches the
                  click and plays the matching local <audio> in the
                  same gesture tick. Going through the server would
                  lose the user-gesture token and play() would
                  reject. Server-initiated alerts (system events)
                  use the LV push_event path instead.
                --%>
                <button
                  type="button"
                  data-chime="done"
                  class="px-3 py-2 text-xs font-mono uppercase tracking-widest rounded border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:border-zinc-300 dark:hover:border-zinc-700 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40 transition-colors focus-ring"
                >
                  Done
                </button>
                <button
                  type="button"
                  data-chime="attention"
                  class="px-3 py-2 text-xs font-mono uppercase tracking-widest rounded border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:border-zinc-300 dark:hover:border-zinc-700 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40 transition-colors focus-ring"
                >
                  Attention
                </button>
                <button
                  type="button"
                  data-chime="alert"
                  class="px-3 py-2 text-xs font-mono uppercase tracking-widest rounded border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:border-zinc-300 dark:hover:border-zinc-700 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40 transition-colors focus-ring"
                >
                  Alert
                </button>
              </div>
            </div>

            <div>
              <div class="flex items-baseline justify-between mb-2">
                <span class="text-[10px] font-mono uppercase tracking-widest text-zinc-500">
                  Activity
                </span>
                <span class="text-[10px] font-mono text-zinc-400 dark:text-zinc-600">
                  {@activity}
                </span>
              </div>
              <div class="flex flex-wrap gap-2">
                <%= for {label, val} <- [{"Idle", "0.0"}, {"Low", "0.33"}, {"Med", "0.66"}, {"High", "1.0"}] do %>
                  <button
                    type="button"
                    phx-click="set_activity"
                    phx-value-level={val}
                    class={[
                      "px-3 py-2 text-xs font-mono uppercase tracking-widest rounded border transition-colors focus-ring",
                      if @activity == val do
                        "border-violet-500 dark:border-violet-400 text-violet-700 dark:text-violet-300 bg-violet-50 dark:bg-violet-900/20"
                      else
                        "border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:border-zinc-300 dark:hover:border-zinc-700 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40"
                      end
                    ]}
                  >
                    {label}
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </section>
      </main>
    </div>
    """
  end

  # A row in the bed picker. Current track gets a subtle violet
  # accent on the indicator dot; the row itself stays quiet.
  defp track_row_classes(true),
    do:
      "group w-full flex items-baseline gap-4 px-2 py-3 text-left transition-colors focus-ring " <>
        "text-zinc-900 dark:text-zinc-100"

  defp track_row_classes(false),
    do:
      "group w-full flex items-baseline gap-4 px-2 py-3 text-left transition-colors focus-ring " <>
        "text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/40"

  # Left-edge indicator dot. Filled violet for the selected row,
  # hollow zinc ring otherwise. Sub-1ch wide so it doesn't push
  # the column layout around.
  defp track_indicator_classes(true),
    do: "inline-block w-1.5 h-1.5 rounded-full bg-violet-500 dark:bg-violet-400 shrink-0"

  defp track_indicator_classes(false),
    do:
      "inline-block w-1.5 h-1.5 rounded-full border border-zinc-300 dark:border-zinc-700 shrink-0"
end
