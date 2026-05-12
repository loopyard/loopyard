defmodule LoopyardWeb.Live.WorkspaceLive.Components.Viewers.GitViewer do
  @moduledoc """
  Git viewer components: status overview (staged/unstaged), commit detail,
  and syntax-highlighted diff viewer. Each is a route-based full-page view.
  """
  use Phoenix.Component

  alias LoopyardWeb.Live.WorkspaceLive.Components.Viewers.Syntax

  # ---------------------------------------------------------------
  # Git overview: staged + unstaged + recent commits
  # ---------------------------------------------------------------

  attr :git_status, :any, default: nil
  attr :git_log, :list, default: []
  attr :base_path, :string, required: true
  attr :volume_name, :string, required: true

  def git_overview(assigns) do
    staged = if is_map(assigns.git_status), do: assigns.git_status[:staged] || [], else: []
    unstaged = if is_map(assigns.git_status), do: assigns.git_status[:unstaged] || [], else: []

    assigns =
      assigns
      |> assign(:staged, staged)
      |> assign(:unstaged, unstaged)

    ~H"""
    <div class="divide-y divide-zinc-200 dark:divide-zinc-700/80">
      <%!-- Loading --%>
      <div :if={@git_log == :loading} class="p-6">
        <div class="animate-pulse space-y-3">
          <div class="h-3 bg-zinc-200 dark:bg-zinc-700 rounded w-1/3"></div>
          <div class="h-3 bg-zinc-200 dark:bg-zinc-700 rounded w-2/3"></div>
          <div class="h-3 bg-zinc-200 dark:bg-zinc-700 rounded w-1/2"></div>
        </div>
      </div>

      <%!-- Staged changes --%>
      <div :if={@staged != []}>
        <div class="text-[10px] font-semibold uppercase tracking-wider text-green-600 dark:text-green-400 px-4 py-2 bg-green-50 dark:bg-green-900/10">
          Staged — ready to commit ({length(@staged)} file{if length(@staged) != 1, do: "s"})
        </div>
        <.file_change
          :for={change <- @staged}
          change={change}
          href={"#{@base_path}/volumes/#{@volume_name}/git/staged/#{change.path}"}
        />
      </div>

      <%!-- Unstaged changes --%>
      <div :if={@unstaged != []}>
        <div class="text-[10px] font-semibold uppercase tracking-wider text-amber-600 dark:text-amber-400 px-4 py-2 bg-amber-50 dark:bg-amber-900/10">
          Unstaged changes ({length(@unstaged)} file{if length(@unstaged) != 1, do: "s"})
        </div>
        <.file_change
          :for={change <- @unstaged}
          change={change}
          href={"#{@base_path}/volumes/#{@volume_name}/git/diff/#{change.path}"}
        />
      </div>

      <%!-- Clean state --%>
      <div
        :if={@staged == [] && @unstaged == [] && is_map(@git_status)}
        class="px-4 py-3 text-sm text-zinc-400 dark:text-zinc-500"
      >
        Working tree clean
      </div>

      <%!-- Recent commits --%>
      <div :if={is_list(@git_log) && @git_log != []}>
        <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          Recent commits
        </div>
        <.link
          :for={commit <- @git_log}
          patch={"#{@base_path}/volumes/#{@volume_name}/git/commits/#{commit.sha}"}
          class="block w-full px-4 py-2 flex items-start gap-3 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <span class="font-mono text-xs text-violet-500 dark:text-violet-400 shrink-0 pt-0.5">
            {String.slice(commit.sha, 0..6)}
          </span>
          <div class="min-w-0 flex-1">
            <div class="text-zinc-700 dark:text-zinc-300 truncate">{commit.message}</div>
            <div class="text-xs text-zinc-400 dark:text-zinc-500">
              {commit.author} · {format_date(commit.date)}
            </div>
          </div>
        </.link>
      </div>

      <%!-- Empty --%>
      <div
        :if={
          is_list(@git_log) && @git_log == [] && is_map(@git_status) && @staged == [] &&
            @unstaged == []
        }
        class="px-4 py-8 text-sm text-zinc-400 dark:text-zinc-500 text-center"
      >
        No git history
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------
  # Commit detail: files changed + stats
  # ---------------------------------------------------------------

  attr :commit, :map, required: true
  attr :base_path, :string, required: true
  attr :volume_name, :string, required: true

  def commit_detail(assigns) do
    ~H"""
    <div class="divide-y divide-zinc-200 dark:divide-zinc-700/80">
      <%!-- Commit header --%>
      <div class="px-4 py-4">
        <div class="flex items-start gap-3">
          <span class="font-mono text-xs text-violet-500 dark:text-violet-400 bg-violet-50 dark:bg-violet-900/20 rounded px-2 py-0.5 shrink-0">
            {String.slice(@commit.sha, 0..6)}
          </span>
          <div class="min-w-0">
            <div class="text-sm font-medium text-zinc-800 dark:text-zinc-200">{@commit.message}</div>
            <div class="text-xs text-zinc-400 dark:text-zinc-500 mt-1">
              {@commit.author} · {format_date(@commit.date)}
            </div>
          </div>
        </div>
      </div>

      <%!-- Files changed --%>
      <div>
        <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          {length(@commit.files)} file{if length(@commit.files) != 1, do: "s"} changed
        </div>
        <.link
          :for={file <- @commit.files}
          patch={"#{@base_path}/volumes/#{@volume_name}/git/commits/#{@commit.sha}/diff/#{file.path}"}
          class="block w-full px-4 py-2 flex items-center gap-3 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group"
        >
          <span class="font-mono text-xs text-zinc-600 dark:text-zinc-400 truncate flex-1">
            {file.path}
          </span>
          <span class="text-xs shrink-0 flex gap-1.5">
            <span :if={file.insertions > 0} class="text-green-600 dark:text-green-400">
              +{file.insertions}
            </span>
            <span :if={file.deletions > 0} class="text-red-600 dark:text-red-400">
              -{file.deletions}
            </span>
          </span>
        </.link>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------
  # Diff viewer: syntax-highlighted unified diff
  # ---------------------------------------------------------------

  attr :diff, :string, required: true
  attr :path, :string, default: nil

  def diff_viewer(assigns) do
    lines = String.split(assigns.diff, "\n")

    language =
      if assigns.path,
        do: LoopyardWeb.Live.WorkspaceLive.Components.Viewers.FileType.language(assigns.path)

    assigns =
      assigns
      |> assign(:lines, lines)
      |> assign(:language, language)
      |> assign(:line_count, length(lines))

    ~H"""
    <div class="flex flex-col overflow-hidden h-full">
      <div
        :if={@path}
        class="flex-none px-4 py-1.5 bg-zinc-100 dark:bg-zinc-800 flex items-center justify-between text-xs text-zinc-500 dark:text-zinc-400"
      >
        <span class="font-mono">{@path}</span>
        <span>{@line_count} lines</span>
      </div>
      <div class="flex-1 overflow-auto highlight">
        <table class="text-xs font-mono leading-relaxed w-full border-collapse">
          <tbody>
            <tr :for={{line, idx} <- Enum.with_index(@lines, 1)} class={diff_line_bg(line)}>
              <td class="select-none text-right pr-2 pl-3 py-0 text-zinc-400 dark:text-zinc-600 align-top w-[1%] whitespace-nowrap opacity-50">
                {idx}
              </td>
              <td class={"pr-4 pl-2 py-0 whitespace-pre-wrap break-all #{diff_line_text(line)}"}>
                {highlight_diff_line(line, @language)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------
  # Shared components
  # ---------------------------------------------------------------

  defp file_change(assigns) do
    ~H"""
    <.link
      patch={@href}
      class="block w-full px-4 py-2 flex items-center gap-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
    >
      <span class={"font-mono text-xs w-5 shrink-0 #{status_color(@change.status)}"}>
        {@change.status}
      </span>
      <span class="text-zinc-600 dark:text-zinc-400 font-mono text-xs truncate">{@change.path}</span>
    </.link>
    """
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp status_color("M"), do: "text-amber-500 dark:text-amber-400"
  defp status_color("A"), do: "text-green-500 dark:text-green-400"
  defp status_color("D"), do: "text-red-500 dark:text-red-400"
  defp status_color("??"), do: "text-blue-500 dark:text-blue-400"
  defp status_color(_), do: "text-zinc-500 dark:text-zinc-400"

  defp diff_line_bg(line) do
    cond do
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
        "bg-green-50/50 dark:bg-green-900/10"

      String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
        "bg-red-50/50 dark:bg-red-900/10"

      true ->
        ""
    end
  end

  defp diff_line_text(line) do
    cond do
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
        "text-green-700 dark:text-green-300"

      String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
        "text-red-700 dark:text-red-300"

      String.starts_with?(line, "@@") ->
        "text-violet-600 dark:text-violet-400"

      String.starts_with?(line, "diff ") or String.starts_with?(line, "index ") ->
        "text-zinc-400 dark:text-zinc-600"

      true ->
        "text-zinc-700 dark:text-zinc-300"
    end
  end

  defp highlight_diff_line(line, nil), do: line
  defp highlight_diff_line("", _), do: Phoenix.HTML.raw("&nbsp;")

  defp highlight_diff_line(line, language) do
    # Strip the +/- prefix for highlighting, then re-add it
    {prefix, code} =
      cond do
        String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
          {"+", String.slice(line, 1..-1//1)}

        String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
          {"-", String.slice(line, 1..-1//1)}

        true ->
          {"", line}
      end

    case Syntax.highlight(code, language) do
      {:safe, html} -> Phoenix.HTML.raw("#{prefix}#{html}")
      plain -> "#{prefix}#{plain}"
    end
  end

  defp format_date(date_str) when is_binary(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff < 60 -> "just now"
          diff < 3600 -> "#{div(diff, 60)}m ago"
          diff < 86400 -> "#{div(diff, 3600)}h ago"
          diff < 604_800 -> "#{div(diff, 86400)}d ago"
          true -> Calendar.strftime(dt, "%b %d")
        end

      _ ->
        date_str
    end
  end

  defp format_date(_), do: ""
end
