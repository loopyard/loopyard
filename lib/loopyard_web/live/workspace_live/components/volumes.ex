defmodule LoopyardWeb.Live.WorkspaceLive.Components.Volumes do
  @moduledoc "Volume detail view component with Info/Files/Git tabs."
  use Phoenix.Component

  import LoopyardWeb.Components.Common, only: [detail_panel: 1, dot: 1, skeleton: 1]

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters,
    only: [derive_volume_description: 1]

  import LoopyardWeb.Format, only: [format_bytes: 1]

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
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
          {@description || @volume_name}
        </span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">
          {section_label(@volume_tab)}
        </span>
        <%!-- MOBILE: volume info lives in the pull-up sheet (desktop: right rail).
             This is the trigger. --%>
        <button
          type="button"
          phx-click={LoopyardWeb.Components.Nav.open_sheet("volume-context")}
          aria-label="Volume details"
          class="md:hidden ml-auto focus-ring inline-flex items-center justify-center min-h-8 min-w-8 rounded-md text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
            <path
              fill-rule="evenodd"
              d="M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0Zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM9 9a.75.75 0 0 0 0 1.5h.253a.25.25 0 0 1 .244.304l-.459 2.066A1.75 1.75 0 0 0 10.747 15H11a.75.75 0 0 0 0-1.5h-.253a.25.25 0 0 1-.244-.304l.459-2.066A1.75 1.75 0 0 0 9.253 9H9Z"
              clip-rule="evenodd"
            />
          </svg>
        </button>
      </:header>
      <div class="flex-1 overflow-y-auto">
        <%!-- No tab bar: Files / Changes / History are their own SWITCHER items
             in the workspace rail (the standard nav), and Info lives in the
             right rail (desktop) / pull-up sheet (mobile). One view per route. --%>
        <div :if={@volume_tab == :files}>
          <.files_tab
            file_tree={@file_tree}
            file_content={@file_content}
            file_path={@file_path}
            browse_path={@browse_path}
            volume_name={@volume_name}
            base_path={@base_path}
          />
        </div>

        <div :if={@volume_tab == :git}>
          <LoopyardWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.git_overview
            git_status={@git_status}
            git_log={@git_log}
            base_path={@base_path}
            volume_name={@volume_name}
            mode={:changes}
          />
        </div>

        <div :if={@volume_tab == :history}>
          <LoopyardWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.git_overview
            git_status={@git_status}
            git_log={@git_log}
            base_path={@base_path}
            volume_name={@volume_name}
            mode={:history}
          />
        </div>
      </div>
    </.detail_panel>
    """
  end

  defp section_label(:git), do: "changes"
  defp section_label(:history), do: "history"
  defp section_label(_), do: "files"

  attr :file_tree, :any, default: nil
  attr :file_content, :any, default: nil
  attr :file_path, :string, default: nil
  attr :browse_path, :string, default: "."
  attr :volume_name, :string, required: true
  attr :base_path, :string, required: true

  defp files_tab(assigns) do
    # Two modes: browsing a directory, or viewing a file
    viewing_file = assigns.file_path && assigns.file_content

    assigns = assign(assigns, :viewing_file, viewing_file)

    ~H"""
    <%= if @viewing_file do %>
      <.file_view
        path={@file_path}
        content={@file_content}
        browse_path={@browse_path}
        base_path={@base_path}
        volume_name={@volume_name}
      />
    <% else %>
      <.directory_listing
        file_tree={@file_tree}
        browse_path={@browse_path}
        base_path={@base_path}
        volume_name={@volume_name}
      />
    <% end %>
    """
  end

  defp file_view(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%!-- File header with breadcrumb back to directory --%>
      <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-1 text-xs">
        <.link
          patch={"#{@base_path}/volumes/#{@volume_name}/files"}
          class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
        >
          /workspace
        </.link>
        <span :for={segment <- path_segments(@path)} class="flex items-center gap-1">
          <span class="text-zinc-400">/</span>
          <.link
            patch={"#{@base_path}/volumes/#{@volume_name}/files/#{segment.path}"}
            class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
          >
            {segment.name}
          </.link>
        </span>
      </div>

      <%!-- File content --%>
      <div :if={@content == :loading} class="flex-1 p-6">
        <.skeleton rows={12} />
      </div>
      <div :if={@content && @content != :loading} class="flex-1 overflow-auto">
        <LoopyardWeb.Live.WorkspaceLive.Components.Viewers.FileViewer.file_viewer
          path={@path}
          content={@content}
          volume_name={@volume_name}
        />
      </div>
    </div>
    """
  end

  defp directory_listing(assigns) do
    ~H"""
    <div>
      <%!-- Breadcrumb --%>
      <div
        :if={@browse_path != "."}
        class="px-4 py-2 flex items-center gap-1 text-xs text-zinc-400 dark:text-zinc-500 border-b border-zinc-200 dark:border-zinc-700/80"
      >
        <.link
          patch={"#{@base_path}/volumes/#{@volume_name}/files"}
          class="hover:text-zinc-600 dark:hover:text-zinc-300"
        >
          /workspace
        </.link>
        <span :for={segment <- path_segments(@browse_path)}>
          <span class="mx-0.5">/</span>
          <.link
            patch={"#{@base_path}/volumes/#{@volume_name}/files/#{segment.path}"}
            class="hover:text-zinc-600 dark:hover:text-zinc-300"
          >
            {segment.name}
          </.link>
        </span>
      </div>

      <%!-- Loading --%>
      <div :if={@file_tree == :loading} class="p-6">
        <.skeleton rows={8} />
      </div>

      <%!-- Tree --%>
      <div :if={is_list(@file_tree)} class="divide-y divide-zinc-100 dark:divide-zinc-800">
        <.link
          :if={@browse_path != "."}
          patch={"#{@base_path}/volumes/#{@volume_name}/files/#{parent_path(@browse_path)}"}
          class="block w-full px-4 py-2 text-sm text-zinc-500 dark:text-zinc-400 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          ..
        </.link>

        <.link
          :for={entry <- @file_tree}
          patch={"#{@base_path}/volumes/#{@volume_name}/files/#{entry.path}"}
          class="flex items-center justify-between px-4 py-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <span class="flex items-center gap-2">
            <span
              :if={entry.type == :dir}
              class="text-zinc-400 dark:text-zinc-500 text-xs w-4 text-center"
            >
              &#x25B8;
            </span>
            <span
              :if={entry.type == :file}
              class="text-zinc-300 dark:text-zinc-600 text-xs w-4 text-center"
            >
              -
            </span>
            <span class={
              if entry.type == :dir,
                do: "text-zinc-700 dark:text-zinc-300 font-medium",
                else: "text-zinc-600 dark:text-zinc-400"
            }>
              {entry.name}{if entry.type == :dir, do: "/"}
            </span>
          </span>
          <span
            :if={entry.type == :file}
            class="text-xs text-zinc-400 dark:text-zinc-500 tabular-nums"
          >
            {format_bytes(entry.size)}
          </span>
        </.link>

        <div
          :if={@file_tree == []}
          class="px-4 py-6 text-sm text-zinc-400 dark:text-zinc-500 text-center"
        >
          Empty directory
        </div>
      </div>
    </div>
    """
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
