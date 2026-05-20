defmodule LoopyardWeb.AmbientSocket do
  @moduledoc """
  Dedicated socket for the ambient audio stream. Separate from
  `UserSocket` so the high-frequency binary audio traffic doesn't
  share a transport with terminal sessions.
  """
  use Phoenix.Socket

  channel "ambient:lobby", LoopyardWeb.AmbientChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
