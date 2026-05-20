defmodule LoopyardWeb.AmbientChannel do
  @moduledoc """
  Pushes ambient audio chunks to subscribed browsers. Receives play /
  stop commands from the client and forwards them to
  `Loopyard.Ambient.Engine`.

  Multiple clients can be connected — they all hear the same audio
  via PubSub fan-out. The engine itself is a singleton.
  """
  use Phoenix.Channel

  alias Loopyard.Events.Ambient, as: Events

  @impl true
  def join("ambient:lobby", _payload, socket) do
    Events.subscribe()
    {:ok, %{playing: Loopyard.Ambient.Engine.playing?()}, socket}
  end

  @impl true
  def handle_in("play", _payload, socket) do
    Loopyard.Ambient.Engine.play()
    broadcast(socket, "state", %{playing: true})
    {:reply, :ok, socket}
  end

  def handle_in("stop", _payload, socket) do
    Loopyard.Ambient.Engine.stop()
    broadcast(socket, "state", %{playing: false})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_info({:audio_chunk, chunk}, socket) do
    push(socket, "chunk", {:binary, chunk})
    {:noreply, socket}
  end
end
