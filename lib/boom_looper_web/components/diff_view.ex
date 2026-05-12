defmodule BoomLooperWeb.Components.DiffView do
  @moduledoc """
  Syntax-highlighted unified diff component.

  Renders a compact diff view with line numbers, +/- prefixes, and
  per-language syntax highlighting. Reuses `Syntax.highlight/2` and
  `FileType.language/1` from the file viewer system — same colors,
  same highlighting engine.

  Used in the chat for edit tool calls. Designed to also work as a
  standalone view for the code browser (future).
  """
  use Phoenix.Component

  alias BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.{FileType, Syntax}

  attr :old, :string, required: true
  attr :new, :string, required: true
  attr :path, :string, default: nil
  attr :link, :string, default: nil

  def diff(assigns) do
    old_lines = String.split(assigns.old, "\n")
    new_lines = String.split(assigns.new, "\n")

    diff_ops = List.myers_difference(old_lines, new_lines)
    language = if assigns.path, do: FileType.language(assigns.path)

    {rows, _, _} = build_rows(diff_ops, language)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:language, language)

    ~H"""
    <div class="mt-1 ml-6 rounded-lg overflow-hidden border border-zinc-200 dark:border-zinc-700/80 text-xs font-mono">
      <div
        :if={@path}
        class="px-3 py-1 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-2"
      >
        <a
          :if={@link}
          href={@link}
          class="text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
        >
          {@path}
        </a>
        <span :if={!@link} class="text-zinc-500 dark:text-zinc-400">{@path}</span>
      </div>
      <table class="w-full border-collapse highlight">
        <tbody>
          <tr :for={row <- @rows} class={row.bg}>
            <td class="select-none text-right pr-1 pl-2 py-0 text-zinc-400 dark:text-zinc-600 align-top w-[1%] whitespace-nowrap opacity-50">
              {row.old_num}
            </td>
            <td class="select-none text-right pr-2 py-0 text-zinc-400 dark:text-zinc-600 align-top w-[1%] whitespace-nowrap opacity-50">
              {row.new_num}
            </td>
            <td class={"pr-3 py-0 whitespace-pre-wrap break-all #{row.text_class}"}>
              <span class="select-none text-zinc-400 dark:text-zinc-600">{row.prefix}</span>{row.content}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Build row structs from myers diff operations.
  # Returns {rows, old_line_num, new_line_num}.
  defp build_rows(diff_ops, language) do
    Enum.reduce(diff_ops, {[], 1, 1}, fn
      {:eq, lines}, {rows, old_n, new_n} ->
        new_rows =
          Enum.with_index(lines, fn line, i ->
            %{
              old_num: old_n + i,
              new_num: new_n + i,
              prefix: " ",
              content: highlight_line(line, language),
              bg: "",
              text_class: "text-zinc-700 dark:text-zinc-300"
            }
          end)

        {rows ++ new_rows, old_n + length(lines), new_n + length(lines)}

      {:del, lines}, {rows, old_n, new_n} ->
        new_rows =
          Enum.with_index(lines, fn line, i ->
            %{
              old_num: old_n + i,
              new_num: "",
              prefix: "-",
              content: highlight_line(line, language),
              bg: "bg-red-50/50 dark:bg-red-900/10",
              text_class: "text-red-700 dark:text-red-300"
            }
          end)

        {rows ++ new_rows, old_n + length(lines), new_n}

      {:ins, lines}, {rows, old_n, new_n} ->
        new_rows =
          Enum.with_index(lines, fn line, i ->
            %{
              old_num: "",
              new_num: new_n + i,
              prefix: "+",
              content: highlight_line(line, language),
              bg: "bg-green-50/50 dark:bg-green-900/10",
              text_class: "text-green-700 dark:text-green-300"
            }
          end)

        {rows ++ new_rows, old_n, new_n + length(lines)}
    end)
  end

  defp highlight_line("", _language), do: Phoenix.HTML.raw("&nbsp;")
  defp highlight_line(line, nil), do: line

  defp highlight_line(line, language) do
    case Syntax.highlight(line, language) do
      {:safe, html} -> Phoenix.HTML.raw(html)
      plain -> plain
    end
  end
end
