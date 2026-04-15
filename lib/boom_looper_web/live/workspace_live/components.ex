defmodule BoomLooperWeb.Live.WorkspaceLive.Components do
  @moduledoc """
  Aggregator module that imports all workspace_live component sub-modules.

  Use `use BoomLooperWeb.Live.WorkspaceLive.Components` to import all
  sidebar, chat, services, states, and formatter components.
  """

  defmacro __using__(_opts) do
    quote do
      import BoomLooperWeb.Live.WorkspaceLive.Components.Sidebar
      import BoomLooperWeb.Live.WorkspaceLive.Components.Chat
      import BoomLooperWeb.Live.WorkspaceLive.Components.Services
      import BoomLooperWeb.Live.WorkspaceLive.Components.Volumes
      import BoomLooperWeb.Live.WorkspaceLive.Components.SyncDetail
      import BoomLooperWeb.Live.WorkspaceLive.Components.ContextPanel
      import BoomLooperWeb.Live.WorkspaceLive.Components.States
      import BoomLooperWeb.Live.WorkspaceLive.Components.Formatters
    end
  end
end
