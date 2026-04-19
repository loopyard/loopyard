defmodule BoomLooperWeb.IExAware do
  @moduledoc """
  Use in LiveViews to subscribe to IExSession updates and maintain the
  `@iex_session` assign. Import the AppHeader component for rendering.

  Usage:

      use BoomLooperWeb.IExAware

  Then in mount (inside `if connected?(socket)` block):

      socket = subscribe_iex(socket)

  The module injects a `handle_info` clause for `:iex_session` messages.
  """

  defmacro __using__(_opts) do
    quote do
      import BoomLooperWeb.Components.AppHeader, only: [header: 1]

      defp subscribe_iex(socket) do
        BoomLooper.Events.IexSession.subscribe()
        Phoenix.Component.assign(socket, :iex_session, BoomLooper.IExSession.current())
      end

      @impl true
      def handle_info(%BoomLooper.Events.IexSession.Changed{state: state}, socket) do
        {:noreply, Phoenix.Component.assign(socket, :iex_session, state)}
      end
    end
  end
end
