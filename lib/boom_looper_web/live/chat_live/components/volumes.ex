defmodule BoomLooperWeb.Live.ChatLive.Components.Volumes do
  @moduledoc "Volume detail view component."
  use Phoenix.Component

  import BoomLooperWeb.Components.Common, only: [detail_panel: 1, dot: 1]
  import BoomLooperWeb.Live.ChatLive.Components.Formatters, only: [derive_volume_description: 1]

  attr :volume_name, :string, required: true
  attr :volumes, :list, required: true
  attr :workspace_id, :string, required: true
  attr :base_path, :string, required: true

  def volume_detail(assigns) do
    vol = Enum.find(assigns.volumes, &(&1.name == assigns.volume_name))
    description = if vol, do: vol[:description] || derive_volume_description(vol.name), else: nil

    vol_type =
      cond do
        is_nil(vol) -> nil
        vol[:type] -> vol.type
        String.contains?(assigns.volume_name, "code") -> :code
        String.contains?(assigns.volume_name, "cache") -> :cache
        true -> :data
      end

    assigns =
      assigns
      |> assign(:vol, vol)
      |> assign(:description, description)
      |> assign(:vol_type, vol_type)
      |> assign(:is_code, vol_type == :code)

    ~H"""
    <.detail_panel>
      <:header>
        <.dot color="bg-blue-400" />
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@description || @volume_name}</span>
        <span :if={@vol_type} class="px-1.5 py-0.5 rounded text-[10px] font-medium bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400">
          {@vol_type}
        </span>
      </:header>
      <div class="flex-1 overflow-y-auto p-6 md:p-8">
        <div :if={@vol} class="max-w-lg space-y-4">
          <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 divide-y divide-zinc-200 dark:divide-zinc-700/80">
            <div class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Name</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">{@volume_name}</span>
            </div>
            <div :if={@vol_type} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Type</span>
              <span class="text-sm text-zinc-700 dark:text-zinc-300">{@vol_type}</span>
            </div>
            <div :if={@description} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Description</span>
              <span class="text-sm text-zinc-700 dark:text-zinc-300">{@description}</span>
            </div>
            <div :if={@vol[:service] && @vol.service != "workspace"} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Service</span>
              <span class="text-sm text-zinc-700 dark:text-zinc-300">{@vol.service}</span>
            </div>
            <div class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Workspace</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">{@workspace_id}</span>
            </div>
          </div>

          <p :if={@is_code} class="text-xs text-zinc-400 dark:text-zinc-500">
            This is the main project source volume. It contains the codebase that agents and services share.
          </p>

          <button
            :if={!@is_code}
            phx-click="delete_volume"
            phx-value-volume_name={@volume_name}
            data-confirm="Delete this volume? All data will be lost."
            class="px-2.5 py-1 rounded-md text-xs font-medium bg-red-50 dark:bg-red-900/20 hover:bg-red-100 dark:hover:bg-red-900/40 text-red-600 dark:text-red-400 transition-colors"
          >
            Delete Volume
          </button>
        </div>
        <div :if={!@vol} class="text-sm text-zinc-400 dark:text-zinc-500">
          Volume not found.
        </div>
      </div>
    </.detail_panel>
    """
  end
end
