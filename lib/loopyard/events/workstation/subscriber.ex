defmodule Loopyard.Events.Workstation.Subscriber do
  @moduledoc """
  Behaviour for LiveViews subscribed to a workstation's topic. Implement
  `on_workstation_credentials_changed/2` explicitly (no `@optional_callbacks`).
  """

  alias Loopyard.Events.Workstation

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_workstation_credentials_changed(Workstation.CredentialsChanged.t(), socket) ::
              result
end
