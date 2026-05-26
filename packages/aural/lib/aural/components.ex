defmodule Aural.Components do
  @moduledoc """
  Phoenix function components for the DOM contract between the
  `:aural` package's JS hook (`createAuralHook`) and any host LV.

  The hook keys off specific element IDs (`#aural-audio`,
  `#aural-toggle`, `#aural-scope-line`, etc.). Rather than asking
  every host to remember and re-type those IDs, the host renders
  these components and the IDs come along for free. Adding or
  renaming an ID is a one-place change here.

      <Aural.Components.audio_elements channel_id={@aural_channel} />
      <Aural.Components.scope class="w-full h-32 text-violet-500" />
      <Aural.Components.toggle_button class="...host-styling...">
        <:label>Play</:label>
      </Aural.Components.toggle_button>

  The components are styling-agnostic — they only emit the IDs the
  hook needs plus whatever `class` / extra attrs the host passes in.
  Host owns layout and aesthetics.
  """
  use Phoenix.Component

  @doc """
  The streaming bed `<audio>` pointed at the channel's
  `stream.mp3`. Chimes are mixed into the bed PCM server-side, so
  no separate audio elements are needed for them anymore.

  `crossorigin="anonymous"` is harmless on same-origin requests
  and required by Safari for the chunked-streaming source.
  """
  attr :channel_id, :string, required: true,
    doc: "Channel ID. Built into the streaming bed URL: /aural/<id>/stream.mp3"

  def audio_elements(assigns) do
    ~H"""
    <audio
      id="aural-audio"
      src={"/aural/#{@channel_id}/stream.mp3"}
      preload="auto"
      crossorigin="anonymous"
    />
    """
  end

  @doc """
  Oscilloscope SVG. The JS hook tweens the `#aural-scope-line`
  polyline 60 fps from server-pushed peak amplitudes. The SVG's
  `viewBox` is fixed at `0 0 800 120`; pass `class` to size and
  color it for your host design.
  """
  attr :class, :string, default: nil
  attr :rest, :global

  def scope(assigns) do
    ~H"""
    <svg
      id="aural-scope"
      viewBox="0 0 800 120"
      preserveAspectRatio="none"
      class={@class}
      aria-hidden="true"
      {@rest}
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
    """
  end

  @doc """
  Play / pause toggle button. The JS hook attaches a click handler
  to `#aural-toggle`, toggles the visibility of `#aural-icon-play`
  and `#aural-icon-pause`, and writes the current state into
  `#aural-toggle-label`.

  The `label` slot is the initial text inside the button — usually
  "Play". The hook overwrites it on play / pause / loading.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :label, doc: "Initial label content (typically the word 'Play')."

  def toggle_button(assigns) do
    ~H"""
    <button
      id="aural-toggle"
      type="button"
      aria-label="Play / pause"
      class={@class}
      {@rest}
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
      <span id="aural-toggle-label">
        <%= render_slot(@label) || "Play" %>
      </span>
    </button>
    """
  end

  @doc """
  A status text span the JS hook writes into. Host controls
  styling. Initial content comes from the `default` slot.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block

  def status(assigns) do
    ~H"""
    <span id="aural-status" class={@class} {@rest}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end
end
