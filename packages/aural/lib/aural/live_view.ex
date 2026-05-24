defmodule Aural.LiveView do
  @moduledoc """
  Helpers a host LiveView calls to wire itself to an Aural channel.
  These are plain functions, not a `use` macro — the LV stays its
  own module with its own mount/render, and the host keeps full
  control of every callback.

  Typical wiring:

      defmodule MyAppWeb.AuralLive do
        use MyAppWeb, :live_view
        alias Aural.LiveView, as: AuralLV

        def mount(%{"channel_id" => channel_id}, _session, socket) do
          {:ok,
           socket
           |> assign(:current_track, :serene)
           |> AuralLV.subscribe(channel_id)}
        end

        def handle_info({:peak, _} = msg, socket),
          do: AuralLV.on_peak(msg, socket)

        def handle_info({:alert, _} = msg, socket),
          do: AuralLV.on_alert(msg, socket)

        def handle_event("aural:pick_track", %{"track" => track}, socket),
          do: AuralLV.pick_track(socket, track)
      end

  The host's `render/1` uses `Aural.Components` for the DOM contract
  and any host-side markup for the rest of the page.
  """

  alias Phoenix.LiveView

  @doc """
  Subscribe the socket process to a channel's alert + peak topics
  (only on the connected pass — `connected?(socket)` is false on
  the initial HTTP render). Assigns `:aural_channel` so subsequent
  helpers can look it up.

  Does NOT subscribe to the MP3 stream — that's the controller's
  job (the byte stream goes to HTTP listeners, not to LV WS).
  """
  @spec subscribe(LiveView.Socket.t(), Aural.Channel.channel_id()) :: LiveView.Socket.t()
  def subscribe(socket, channel_id) when is_binary(channel_id) do
    if LiveView.connected?(socket) do
      Aural.Channel.subscribe_alerts(channel_id)
      Aural.Channel.subscribe_peaks(channel_id)
    end

    Phoenix.Component.assign(socket, :aural_channel, channel_id)
  end

  @doc """
  Handle a `{:peak, %{p: float, s: [float]}}` message by pushing it
  to the client as a `"peak"` event. Returns the standard
  `{:noreply, socket}` tuple a `handle_info/2` clause needs.
  """
  @spec on_peak({:peak, map()}, LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def on_peak({:peak, payload}, socket) do
    {:noreply, LiveView.push_event(socket, "peak", payload)}
  end

  @doc """
  Handle a `{:alert, kind}` message by pushing it to the client as
  an `"alert"` event so the JS hook can play the local chime WAV.
  """
  @spec on_alert({:alert, String.t()}, LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def on_alert({:alert, kind}, socket) do
    {:noreply, LiveView.push_event(socket, "alert", %{kind: kind})}
  end

  @doc """
  Apply a `pick_track` event coming from the host's UI: tells the
  channel, updates `:current_track`, and nudges the client to call
  `audio.play()` (the LV pushes a `"play"` event the JS hook
  listens for). `track` is a string from `phx-value-track`.
  """
  @spec pick_track(LiveView.Socket.t(), String.t()) ::
          {:noreply, LiveView.Socket.t()}
  def pick_track(socket, track) when is_binary(track) do
    track_atom = String.to_existing_atom(track)
    Aural.Channel.pick_track(socket.assigns.aural_channel, track_atom)

    socket =
      socket
      |> Phoenix.Component.assign(:current_track, track_atom)
      |> LiveView.push_event("play", %{})

    {:noreply, socket}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  @doc """
  Apply a `set_activity` event from the host's UI.
  `level` is a string like `"0.66"` from `phx-value-level`.
  """
  @spec set_activity(LiveView.Socket.t(), String.t()) ::
          {:noreply, LiveView.Socket.t()}
  def set_activity(socket, level) when is_binary(level) do
    case Float.parse(level) do
      {f, _} -> Aural.Channel.set_activity(socket.assigns.aural_channel, f)
      _ -> :ok
    end

    {:noreply, Phoenix.Component.assign(socket, :activity, level)}
  end

  @doc """
  Apply a `fire` event from the host's UI (or anywhere). `kind` is
  one of `"done"`, `"attention"`, `"alert"`.
  """
  @spec fire(LiveView.Socket.t(), String.t()) :: {:noreply, LiveView.Socket.t()}
  def fire(socket, kind) when is_binary(kind) do
    Aural.Channel.fire(socket.assigns.aural_channel, kind)
    {:noreply, socket}
  end
end
