defmodule LoopyardWeb.Live.WorkspaceLive.Components do
  @moduledoc """
  Aggregator module that imports all workspace_live component sub-modules.

  Use `use LoopyardWeb.Live.WorkspaceLive.Components` to import all
  sidebar, chat, services, states, and formatter components.
  """

  defmacro __using__(_opts) do
    quote do
      import LoopyardWeb.Live.WorkspaceLive.Components.Sidebar
      import LoopyardWeb.Live.WorkspaceLive.Components.Chat
      import LoopyardWeb.Live.WorkspaceLive.Components.Services
      import LoopyardWeb.Live.WorkspaceLive.Components.Volumes
      import LoopyardWeb.Live.WorkspaceLive.Components.SyncDetail
      import LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel
      import LoopyardWeb.Live.WorkspaceLive.Components.States
      import LoopyardWeb.Live.WorkspaceLive.Components.Formatters
      import LoopyardWeb.Live.WorkspaceLive.Components.SetupProgress
    end
  end
end
