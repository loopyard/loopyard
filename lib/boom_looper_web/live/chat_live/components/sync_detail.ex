defmodule BoomLooperWeb.Live.ChatLive.Components.SyncDetail do
  @moduledoc "Sync detail view component for local workspace file sync."
  use Phoenix.Component

  import BoomLooperWeb.Format, only: [shorten_path: 1]

  @button_class "px-2.5 py-1 rounded-md text-xs font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 text-zinc-600 dark:text-zinc-300 transition-colors"

  attr :sync_status, :map, default: nil
  attr :workspace_id, :string, required: true
  attr :workspace, :map, required: true

  def sync_detail(assigns) do
    sync = assigns.sync_status || %{}
    status = Map.get(sync, :status, :stopped)
    last_error = Map.get(sync, :last_error)

    assigns =
      assigns
      |> assign(:sync, sync)
      |> assign(:status, status)
      |> assign(:last_error, last_error)
      |> assign(:button_class, @button_class)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        <div class={"w-2 h-2 rounded-full flex-none #{dot_class(@status)}"}></div>
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Local Sync</span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">{status_label(@status)}</span>
      </div>
      <div class="flex-1 overflow-y-auto p-6 md:p-8">
        <div class="max-w-lg space-y-4">
          <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 divide-y divide-zinc-200 dark:divide-zinc-700/80">
            <div class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Status</span>
              <span class={"text-sm font-medium #{status_text_class(@status)}"}>{status_label(@status)}</span>
            </div>
            <div :if={@last_error} class="px-4 py-3">
              <span class="text-xs text-zinc-400 dark:text-zinc-500 block mb-1">Last Error</span>
              <span class="text-sm text-red-500 dark:text-red-400">{@last_error}</span>
            </div>
            <div class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Workspace</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">{@workspace_id}</span>
            </div>
            <div :if={@workspace[:path]} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-400 dark:text-zinc-500">Worktree Path</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300 truncate max-w-[300px]" title={@workspace.path}>{shorten_path(@workspace.path)}</span>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <button
              phx-click="sync_restart"
              phx-value-workspace-id={@workspace_id}
              class={@button_class}
            >
              Restart
            </button>
            <%= if @status == :paused do %>
              <button
                phx-click="sync_resume"
                phx-value-workspace-id={@workspace_id}
                class={@button_class}
              >
                Resume
              </button>
            <% else %>
              <button
                phx-click="sync_pause"
                phx-value-workspace-id={@workspace_id}
                class={@button_class}
              >
                Pause
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp dot_class(:running), do: "bg-emerald-500"
  defp dot_class(:paused), do: "bg-amber-400"
  defp dot_class(:errored), do: "bg-red-500"
  defp dot_class(:starting), do: "bg-blue-400 animate-pulse"
  defp dot_class(_), do: "bg-zinc-400"

  defp status_label(:running), do: "running"
  defp status_label(:paused), do: "paused"
  defp status_label(:errored), do: "error"
  defp status_label(:starting), do: "starting"
  defp status_label(:stopped), do: "stopped"
  defp status_label(other), do: to_string(other)

  defp status_text_class(:running), do: "text-emerald-600 dark:text-emerald-400"
  defp status_text_class(:paused), do: "text-amber-600 dark:text-amber-400"
  defp status_text_class(:errored), do: "text-red-600 dark:text-red-400"
  defp status_text_class(_), do: "text-zinc-600 dark:text-zinc-400"

end
