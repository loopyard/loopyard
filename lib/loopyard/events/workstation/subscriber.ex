defmodule Loopyard.Events.Workstation.Subscriber do
  @moduledoc """
  Behaviour for LiveViews subscribed to a workstation's topic. Implement every
  callback explicitly (no `@optional_callbacks`).
  """

  alias Loopyard.Events.Workstation

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_workstation_credentials_changed(Workstation.CredentialsChanged.t(), socket) ::
              result

  @callback on_workstation_sign_in_changed(Workstation.SignInChanged.t(), socket) :: result
end
