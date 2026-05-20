defmodule LoopyardWeb.AmbientLive do
  @moduledoc """
  Listening page for the ambient soundtrack. The audio is served as
  a streaming WAV from `AmbientStreamController` and played by a
  native `<audio>` element. JS hook just toggles play/pause and
  taps the audio output for the SVG oscilloscope.
  """
  use LoopyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Ambient")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="ambient-page"
      phx-hook="Ambient"
      class="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-zinc-950 text-zinc-200 flex flex-col items-center justify-center px-6 py-12 select-none"
    >
      <audio id="ambient-audio" src={~p"/ambient/stream.mp3"} preload="none"></audio>

      <div class="text-center mb-12">
        <h1 class="text-2xl font-light tracking-wide text-zinc-100">Loopyard Ambient</h1>
        <p class="text-sm text-zinc-500 mt-2 font-light">
          Generated in pure Elixir. Streamed to your browser.
        </p>
      </div>
      <button
        id="ambient-toggle"
        type="button"
        aria-label="Play"
        class="group relative w-44 h-44 rounded-full bg-zinc-800 hover:bg-zinc-700 active:bg-zinc-600 border border-zinc-700 hover:border-zinc-500 transition-all duration-300 flex items-center justify-center shadow-[0_0_60px_-15px_rgba(168,85,247,0.5)] hover:shadow-[0_0_80px_-10px_rgba(168,85,247,0.7)]"
      >
        <svg
          id="ambient-icon-play"
          class="w-16 h-16 text-zinc-200 ml-2"
          viewBox="0 0 24 24"
          fill="currentColor"
          aria-hidden="true"
        >
          <path d="M8 5v14l11-7z" />
        </svg>
        <svg
          id="ambient-icon-pause"
          class="w-16 h-16 text-zinc-200 hidden"
          viewBox="0 0 24 24"
          fill="currentColor"
          aria-hidden="true"
        >
          <path d="M6 4h4v16H6zM14 4h4v16h-4z" />
        </svg>
      </button>
      <div class="w-full max-w-3xl mt-16">
        <svg
          id="ambient-scope"
          viewBox="0 0 800 120"
          preserveAspectRatio="none"
          class="w-full h-24 opacity-70"
          aria-hidden="true"
        >
          <polyline
            id="ambient-scope-line"
            points="0,60 800,60"
            fill="none"
            stroke="rgb(168 85 247 / 0.7)"
            stroke-width="1.2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      <div id="ambient-status" class="mt-6 text-xs text-zinc-500 font-light h-4">
        Click to play
      </div>
    </div>
    """
  end
end
