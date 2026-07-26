defmodule LoopyardWeb.Live.WorkspaceLive.Components.SyncDetail do
  @moduledoc "Sync detail view component for local workspace file sync."
  use Phoenix.Component

  import LoopyardWeb.Components.Common, only: [detail_panel: 1, control_btn: 1, dot: 1]
  import LoopyardWeb.Format, only: [shorten_path: 1]

  attr :sync_status, :map, default: nil
  attr :workspace_id, :string, required: true
  attr :workspace, :map, required: true

  def sync_detail(assigns) do
    sync = assigns.sync_status || %{}
    status = Map.get(sync, :status, :stopped)

    assigns =
      assigns
      |> assign(:sync, sync)
      |> assign(:status, status)
      |> assign(:last_error, Map.get(sync, :last_error))

    ~H"""
    <.detail_panel>
      <:header>
        <.dot color={dot_color(@status)} />
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Local Sync</span>
        <span class="text-xs text-zinc-500 dark:text-zinc-400">{status_label(@status)}</span>
      </:header>
      <div class="flex-1 overflow-y-auto p-6 md:p-8">
        <div class="max-w-lg space-y-4">
          <div class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 divide-y divide-zinc-200 dark:divide-zinc-700/80">
            <div class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Status</span>
              <span class={"text-sm font-medium #{status_text_class(@status)}"}>
                {status_label(@status)}
              </span>
            </div>
            <div :if={@last_error} class="px-4 py-3">
              <span class="text-xs text-zinc-500 dark:text-zinc-400 block mb-1">Last Error</span>
              <span class="text-sm text-red-500 dark:text-red-400">{@last_error}</span>
            </div>
            <div class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Workspace</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">{@workspace_id}</span>
            </div>
            <div :if={@workspace[:path]} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Worktree Path</span>
              <span
                class="text-sm font-mono text-zinc-700 dark:text-zinc-300 truncate max-w-[300px]"
                title={@workspace.path}
              >
                {shorten_path(@workspace.path)}
              </span>
            </div>
          </div>

          <%!-- Mutagen details --%>
          <% details = @sync[:details] %>
          <div
            :if={details}
            class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 divide-y divide-zinc-200 dark:divide-zinc-700/80"
          >
            <div :if={details[:status_text]} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Mutagen</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">
                {details.status_text}
              </span>
            </div>
            <div :if={details[:alpha_files]} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Host files</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">
                {details.alpha_files.files} ({details.alpha_files.size})
              </span>
            </div>
            <div :if={details[:beta_files]} class="px-4 py-3 flex items-center justify-between">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Container files</span>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300">
                {details.beta_files.files} ({details.beta_files.size})
              </span>
            </div>
            <div
              :if={details[:conflicts] && details.conflicts > 0}
              class="px-4 py-3 flex items-center justify-between"
            >
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Conflicts</span>
              <span class="text-sm font-medium text-amber-500">{details.conflicts}</span>
            </div>
            <div
              :if={details[:scan_problems] && details.scan_problems > 0}
              class="px-4 py-3 flex items-center justify-between"
            >
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Scan problems</span>
              <span class="text-sm font-medium text-amber-500">{details.scan_problems}</span>
            </div>
            <div class="px-4 py-3 flex items-center gap-3">
              <span class="text-xs text-zinc-500 dark:text-zinc-400">Connections</span>
              <span class="flex items-center gap-1.5 text-xs">
                <span class={"w-1.5 h-1.5 rounded-full #{if details[:alpha_connected], do: "bg-green-500", else: "bg-red-500"}"}></span>
                host
              </span>
              <span class="flex items-center gap-1.5 text-xs">
                <span class={"w-1.5 h-1.5 rounded-full #{if details[:beta_connected], do: "bg-green-500", else: "bg-red-500"}"}></span>
                container
              </span>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <.control_btn phx-click="sync_restart" phx-value-workspace-id={@workspace_id}>
              Restart
            </.control_btn>
            <.control_btn
              :if={@status == :paused}
              phx-click="sync_resume"
              phx-value-workspace-id={@workspace_id}
            >
              Resume
            </.control_btn>
            <.control_btn
              :if={@status != :paused}
              phx-click="sync_pause"
              phx-value-workspace-id={@workspace_id}
            >
              Pause
            </.control_btn>
          </div>
        </div>
      </div>
    </.detail_panel>
    """
  end

  defp dot_color(:running), do: "bg-emerald-500"
  defp dot_color(:paused), do: "bg-amber-400"
  defp dot_color(:errored), do: "bg-red-500"
  defp dot_color(:starting), do: "bg-blue-400 animate-pulse"
  defp dot_color(_), do: "bg-zinc-400"

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
