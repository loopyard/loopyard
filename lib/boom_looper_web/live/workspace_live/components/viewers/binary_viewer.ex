defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.BinaryViewer do
  @moduledoc "Placeholder for binary files that can't be previewed."
  use Phoenix.Component

  import BoomLooperWeb.Format, only: [format_bytes: 1]

  attr :path, :string, required: true
  attr :size, :integer, default: nil

  def binary_viewer(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center p-8 text-center">
      <div class="w-12 h-12 rounded-lg bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mb-3">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-6 h-6 text-zinc-400">
          <path d="M3.5 2A1.5 1.5 0 0 0 2 3.5v9A1.5 1.5 0 0 0 3.5 14h9a1.5 1.5 0 0 0 1.5-1.5v-7A1.5 1.5 0 0 0 12.5 4H9.621a1.5 1.5 0 0 1-1.06-.44L7.439 2.44A1.5 1.5 0 0 0 6.378 2H3.5Z" />
        </svg>
      </div>
      <div class="text-sm font-medium text-zinc-700 dark:text-zinc-300">{Path.basename(@path)}</div>
      <div class="text-xs text-zinc-400 dark:text-zinc-500 mt-1">Binary file — no preview available</div>
      <div :if={@size} class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5">{format_bytes(@size)}</div>
    </div>
    """
  end
end
