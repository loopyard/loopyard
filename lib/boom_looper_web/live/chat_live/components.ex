defmodule BoomLooperWeb.Live.ChatLive.Components do
  @moduledoc """
  Aggregator module that imports all chat_live component sub-modules.

  Use `use BoomLooperWeb.Live.ChatLive.Components` to import all
  sidebar, chat, services, states, and formatter components.
  """

  defmacro __using__(_opts) do
    quote do
      import BoomLooperWeb.Live.ChatLive.Components.Sidebar
      import BoomLooperWeb.Live.ChatLive.Components.Chat
      import BoomLooperWeb.Live.ChatLive.Components.Services
      import BoomLooperWeb.Live.ChatLive.Components.Volumes
      import BoomLooperWeb.Live.ChatLive.Components.SyncDetail
      import BoomLooperWeb.Live.ChatLive.Components.ContextPanel
      import BoomLooperWeb.Live.ChatLive.Components.States
      import BoomLooperWeb.Live.ChatLive.Components.Formatters
    end
  end
end
