defmodule LoopyardWeb.Live.WorkspaceLive.MainContent do
  @moduledoc """
  The workspace view's center pane — the `live_action` router that picks which
  screen fills the area between the left switcher and the right rail (setup
  progress, the stopped-cluster screen, service/console/volume/git views, the
  booting/empty states, or the agent chat).

  Extracted from `LoopyardWeb.WorkspaceLive.render/1` to keep that file under
  its line cap. Pure rendering — it reads the full assigns (passed as
  `<.main_content {assigns} />`) and owns no state.
  """
  use LoopyardWeb, :html
  use LoopyardWeb.Live.WorkspaceLive.Components

  def main_content(assigns) do
    ~H"""
    <%!-- When the workspace setup saga hasn't finished (volume not yet
         populated) take over the main content area. The sidebar keeps
         showing so the user has navigation; the workspace content is
         replaced with the SetupProgress step list. --%>
    <%= if !Loopyard.Workspace.ready?(@workspace_entry) do %>
      <.setup_progress
        setup={Map.get(@workspace_entry, :setup, %{phase: :pending})}
        workspace_id={@workspace.id}
        workspace_name={@workspace_entry[:name] || ""}
      />
    <% else %>
      <%!-- Stopped-workspace screen only when the user isn't looking
           at a specific agent. Agent history stays readable regardless
           of service state — sending new messages is what the running
           workspace gates. --%>
      <%!-- Cluster is down → show the big "Start workspace" empty
           state ONLY on the workspace root and the agent-less
           chat/container routes. Volume, git, sync, service, and
           new-agent views all carry their own content that should
           render regardless of cluster state — overlaying the
           start screen on top of them is the bug we're avoiding. --%>
      <.workspace_not_running
        :if={
          @workspace_state in [:stopped, :starting] && !@selected_agent &&
            is_nil(@booting_agent_id) &&
            @live_action in [:index, :chat, :container]
        }
        workspace={@workspace}
        workspace_state={@workspace_state}
        base_path={@base_path}
      />
      <.new_agent_screen
        :if={@live_action == :new}
        workspace={@workspace}
        base_path={@base_path}
      />
      <.service_log_view
        :if={@live_action == :service}
        service_name={@selected_service}
        service_statuses={@service_statuses}
        logs={@service_logs}
        base_path={@base_path}
        host={@host}
        workspace_state={@workspace_state}
      />
      <.console_view
        :if={@live_action == :console}
        service_name={@selected_service}
        container={@console_container}
      />
      <.all_services_view :if={@live_action == :services} all_service_logs={@all_service_logs} />
      <.volume_detail
        :if={@live_action in [:volume, :volume_files_root, :volume_file, :volume_git]}
        volume_name={@selected_volume}
        volumes={@volumes}
        workspace_id={@workspace.id}
        base_path={@base_path}
        volume_tab={@volume_tab}
        file_tree={@file_tree}
        file_content={@file_content}
        file_path={@file_path}
        browse_path={@browse_path}
        git_log={@git_log}
        git_status={@git_status}
        diff_content={@diff_content}
        supports_git={@supports_git}
      />
      <%= if @live_action in [:git_diff, :git_staged_diff] && @diff_content && @diff_content != :loading do %>
        <div class="flex flex-col h-full">
          <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-2 text-xs">
            <.link
              patch={"#{@base_path}/volumes/#{@selected_volume}/git"}
              class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
            >
              ← Git
            </.link>
            <span class="text-zinc-300 dark:text-zinc-600">·</span>
            <span class="font-mono text-zinc-600 dark:text-zinc-400">{@diff_path}</span>
            <span
              :if={@live_action == :git_staged_diff}
              class="text-green-600 dark:text-green-400 text-[10px] font-semibold uppercase"
            >
              staged
            </span>
          </div>
          <LoopyardWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.diff_viewer
            diff={@diff_content}
            path={@diff_path}
          />
        </div>
      <% end %>
      <%= if @live_action == :git_commit && is_map(@commit_detail) do %>
        <div class="flex flex-col h-full">
          <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 text-xs">
            <.link
              patch={"#{@base_path}/volumes/#{@selected_volume}/git"}
              class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
            >
              ← Git
            </.link>
          </div>
          <LoopyardWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.commit_detail
            commit={@commit_detail}
            base_path={@base_path}
            volume_name={@selected_volume}
          />
        </div>
      <% end %>
      <%= if @live_action == :git_commit_file && @diff_content && @diff_content != :loading do %>
        <div class="flex flex-col h-full">
          <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-2 text-xs">
            <.link
              patch={"#{@base_path}/volumes/#{@selected_volume}/git/commits/#{@commit_sha}"}
              class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
            >
              ← {String.slice(@commit_sha || "", 0..6)}
            </.link>
            <span class="text-zinc-300 dark:text-zinc-600">·</span>
            <span class="font-mono text-zinc-600 dark:text-zinc-400">{@diff_path}</span>
          </div>
          <LoopyardWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.diff_viewer
            diff={@diff_content}
            path={@diff_path}
          />
        </div>
      <% end %>
      <.sync_detail
        :if={@live_action == :sync}
        sync_status={@sync_status}
        workspace_id={@workspace.id}
        workspace={@workspace}
      />
      <.booting_screen
        :if={@live_action in [:index, :chat, :container] && @booting_agent_id && !@selected_agent}
        agent_id={@booting_agent_id}
        status={@boot_status}
        boot_log={@boot_log}
      />
      <.empty_state :if={
        @live_action in [:index, :chat, :container] && !@booting_agent_id && !@selected_agent
      } />
      <.agent_view
        :if={@live_action in [:index, :chat, :container, :context_panel] && @selected_agent}
        {assigns}
      />
    <% end %>
    """
  end
end
