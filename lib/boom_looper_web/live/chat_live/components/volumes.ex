defmodule BoomLooperWeb.Live.ChatLive.Components.Volumes do
  @moduledoc "Volume detail view component with Info/Files/Git tabs."
  use Phoenix.Component

  import BoomLooperWeb.Components.Common, only: [detail_panel: 1, dot: 1, skeleton: 1]
  import BoomLooperWeb.Live.ChatLive.Components.Formatters, only: [derive_volume_description: 1]
  import BoomLooperWeb.Format, only: [format_bytes: 1]

  attr :volume_name, :string, required: true
  attr :volumes, :list, required: true
  attr :workspace_id, :string, required: true
  attr :base_path, :string, required: true
  attr :volume_tab, :atom, default: :info
  attr :file_tree, :any, default: nil
  attr :file_content, :any, default: nil
  attr :file_path, :string, default: nil
  attr :browse_path, :string, default: "."
  attr :git_log, :list, default: []
  attr :git_status, :list, default: []
  attr :diff_content, :string, default: nil
  attr :supports_git, :boolean, default: false

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
      <div class="flex-1 overflow-y-auto">
        <%!-- Tab bar - only show Files/Git for code volumes --%>
        <div :if={@is_code} class="border-b border-zinc-200 dark:border-zinc-700/80 px-4">
          <nav class="flex gap-4 -mb-px">
            <.tab_button label="Info" tab={:info} current={@volume_tab} />
            <.tab_button label="Files" tab={:files} current={@volume_tab} />
            <.tab_button :if={@supports_git} label="Git" tab={:git} current={@volume_tab} />
          </nav>
        </div>

        <%!-- Info tab --%>
        <div :if={@volume_tab == :info} class="p-6 md:p-8">
          <.info_tab vol={@vol} vol_type={@vol_type} description={@description} volume_name={@volume_name} workspace_id={@workspace_id} is_code={@is_code} />
        </div>

        <%!-- Files tab --%>
        <div :if={@volume_tab == :files}>
          <.files_tab file_tree={@file_tree} file_content={@file_content} file_path={@file_path} browse_path={@browse_path} volume_name={@volume_name} />
        </div>

        <%!-- Git tab --%>
        <div :if={@volume_tab == :git}>
          <.git_tab git_log={@git_log} git_status={@git_status} diff_content={@diff_content} />
        </div>
      </div>
    </.detail_panel>
    """
  end

  defp tab_button(assigns) do
    active = assigns.tab == assigns.current

    classes =
      if active do
        "py-2.5 text-xs font-medium border-b-2 border-violet-500 text-violet-600 dark:text-violet-400"
      else
        "py-2.5 text-xs font-medium border-b-2 border-transparent text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 cursor-pointer"
      end

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <button phx-click="volume_tab" phx-value-tab={@tab} class={@classes}>
      {@label}
    </button>
    """
  end

  attr :vol, :map, default: nil
  attr :vol_type, :atom, default: nil
  attr :description, :string, default: nil
  attr :volume_name, :string, required: true
  attr :workspace_id, :string, required: true
  attr :is_code, :boolean, default: false

  defp info_tab(assigns) do
    ~H"""
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
    """
  end

  attr :file_tree, :any, default: nil
  attr :file_content, :any, default: nil
  attr :file_path, :string, default: nil
  attr :browse_path, :string, default: "."
  attr :volume_name, :string, required: true

  defp files_tab(assigns) do
    ~H"""
    <div class="divide-y divide-zinc-200 dark:divide-zinc-700/80">
      <%!-- Breadcrumb path --%>
      <div :if={@browse_path != "."} class="px-4 py-2 flex items-center gap-1 text-xs text-zinc-400 dark:text-zinc-500">
        <button phx-click="browse_dir" phx-value-path="." class="hover:text-zinc-600 dark:hover:text-zinc-300">
          /workspace
        </button>
        <span :for={segment <- path_segments(@browse_path)}>
          <span class="mx-0.5">/</span>
          <button phx-click="browse_dir" phx-value-path={segment.path} class="hover:text-zinc-600 dark:hover:text-zinc-300">
            {segment.name}
          </button>
        </span>
      </div>

      <%!-- Loading state --%>
      <div :if={@file_tree == :loading} class="p-6">
        <.skeleton rows={8} />
      </div>

      <%!-- Tree listing --%>
      <div :if={is_list(@file_tree)} class="divide-y divide-zinc-100 dark:divide-zinc-800">
        <%!-- Parent dir link --%>
        <button
          :if={@browse_path != "."}
          phx-click="browse_dir"
          phx-value-path={parent_path(@browse_path)}
          class="w-full px-4 py-2 flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <span class="text-zinc-400">..</span>
        </button>

        <button
          :for={entry <- @file_tree}
          phx-click={if entry.type == :dir, do: "browse_dir", else: "view_file"}
          phx-value-path={entry.path}
          phx-value-volume={@volume_name}
          class="w-full px-4 py-2 flex items-center justify-between text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <span class="flex items-center gap-2">
            <span :if={entry.type == :dir} class="text-zinc-400 dark:text-zinc-500 text-xs w-4 text-center">&#x25B8;</span>
            <span :if={entry.type == :file} class="text-zinc-300 dark:text-zinc-600 text-xs w-4 text-center">-</span>
            <span class={if entry.type == :dir, do: "text-zinc-700 dark:text-zinc-300 font-medium", else: "text-zinc-600 dark:text-zinc-400"}>
              {entry.name}{if entry.type == :dir, do: "/"}
            </span>
          </span>
          <span :if={entry.type == :file} class="text-xs text-zinc-400 dark:text-zinc-500 tabular-nums">
            {format_bytes(entry.size)}
          </span>
        </button>

        <div :if={@file_tree == []} class="px-4 py-6 text-sm text-zinc-400 dark:text-zinc-500 text-center">
          Empty directory
        </div>
      </div>

      <%!-- File content viewer --%>
      <div :if={@file_content} class="border-t border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-2 flex items-center justify-between bg-zinc-50 dark:bg-zinc-800/50">
          <span class="text-xs font-mono text-zinc-500 dark:text-zinc-400">{@file_path}</span>
          <button phx-click="close_file_viewer" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
            Close
          </button>
        </div>
        <BoomLooperWeb.Live.ChatLive.Components.Viewers.FileViewer.file_viewer path={@file_path} content={@file_content} />
      </div>
    </div>
    """
  end

  attr :git_log, :list, default: []
  attr :git_status, :list, default: []
  attr :diff_content, :string, default: nil

  defp git_tab(assigns) do
    ~H"""
    <div class="divide-y divide-zinc-200 dark:divide-zinc-700/80">
      <%!-- Loading state --%>
      <div :if={@git_log == :loading} class="p-6">
        <.skeleton rows={6} />
      </div>

      <%!-- Working tree changes --%>
      <div :if={is_list(@git_status) && @git_status != []}>
        <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          Working tree changes
        </div>
        <button
          :for={change <- @git_status}
          phx-click="view_diff"
          phx-value-path={change.path}
          class="w-full px-4 py-2 flex items-center gap-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <span class={status_color(change.status)}>{change.status}</span>
          <span class="text-zinc-600 dark:text-zinc-400 font-mono text-xs truncate">{change.path}</span>
        </button>
      </div>

      <%!-- Recent commits --%>
      <div :if={is_list(@git_log) && @git_log != []}>
        <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          Recent commits
        </div>
        <button
          :for={commit <- @git_log}
          phx-click="view_commit"
          phx-value-sha={commit.sha}
          class="w-full px-4 py-1.5 flex items-start gap-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <span class="font-mono text-xs text-violet-500 dark:text-violet-400 shrink-0">{String.slice(commit.sha, 0..6)}</span>
          <span class="text-zinc-700 dark:text-zinc-300 truncate">{commit.message}</span>
          <span class="text-xs text-zinc-400 dark:text-zinc-500 shrink-0 ml-auto">{commit.author}</span>
        </button>
      </div>

      <%!-- Empty state --%>
      <div :if={is_list(@git_log) && @git_log == [] && is_list(@git_status) && @git_status == []} class="px-4 py-6 text-sm text-zinc-400 dark:text-zinc-500 text-center">
        No git history available
      </div>

      <%!-- Diff viewer --%>
      <div :if={@diff_content}>
        <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 flex items-center justify-between">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500">Diff</span>
          <button phx-click="close_diff" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
            Close
          </button>
        </div>
        <pre class="p-4 text-xs font-mono overflow-x-auto max-h-[60vh] overflow-y-auto whitespace-pre-wrap break-all"><%= colorize_diff(@diff_content) %></pre>
      </div>
    </div>
    """
  end

  defp status_color(status) do
    class =
      case status do
        "M" -> "text-amber-500 dark:text-amber-400"
        "A" -> "text-green-500 dark:text-green-400"
        "D" -> "text-red-500 dark:text-red-400"
        "??" -> "text-blue-500 dark:text-blue-400"
        _ -> "text-zinc-500 dark:text-zinc-400"
      end

    "font-mono text-xs w-5 shrink-0 #{class}"
  end

  defp colorize_diff(content) do
    content
    |> String.split("\n")
    |> Enum.map(fn line ->
      escaped = Phoenix.HTML.html_escape(line) |> Phoenix.HTML.safe_to_string()

      class =
        cond do
          String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
            "text-green-600 dark:text-green-400"

          String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
            "text-red-600 dark:text-red-400"

          String.starts_with?(line, "@@") ->
            "text-violet-500 dark:text-violet-400"

          true ->
            "text-zinc-600 dark:text-zinc-400"
        end

      "<span class=\"#{class}\">#{escaped}</span>"
    end)
    |> Enum.join("\n")
    |> Phoenix.HTML.raw()
  end

  defp path_segments(browse_path) do
    parts = Path.split(browse_path)

    parts
    |> Enum.with_index()
    |> Enum.map(fn {part, idx} ->
      %{name: part, path: Enum.take(parts, idx + 1) |> Path.join()}
    end)
  end

  defp parent_path(path) do
    parent = Path.dirname(path)
    if parent == path or parent == "/", do: ".", else: parent
  end
end
