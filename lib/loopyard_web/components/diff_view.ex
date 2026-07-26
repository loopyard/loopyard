defmodule LoopyardWeb.Components.DiffView do
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

  alias LoopyardWeb.Live.WorkspaceLive.Components.Viewers.{FileType, Syntax}

  attr :old, :string, required: true
  attr :new, :string, required: true
  attr :path, :string, default: nil
  attr :link, :string, default: nil

  # Cap on agent-supplied diff input. Past this size, myers_difference cost
  # (O(N·M) memory) and the LiveView push payload aren't worth the rich
  # render — show a stub that links to the file viewer instead.
  @max_diff_bytes 64 * 1024
  @max_diff_lines 500

  def diff(assigns) do
    old_size = byte_size(assigns.old)
    new_size = byte_size(assigns.new)

    if old_size + new_size > @max_diff_bytes do
      render_too_large(assigns, old_size + new_size)
    else
      old_lines = String.split(assigns.old, "\n")
      new_lines = String.split(assigns.new, "\n")

      if length(old_lines) + length(new_lines) > @max_diff_lines * 2 do
        render_too_large(assigns, old_size + new_size)
      else
        diff_ops = List.myers_difference(old_lines, new_lines)
        language = if assigns.path, do: FileType.language(assigns.path)

        # Highlight each side in ONE tokenize pass (see Syntax.highlight_lines/2).
        # Per-line highlighting was O(lines) NIF calls at ~18ms each — a 70-line
        # edit took >1s to render, stalling every chat page load that scrolled
        # past it. These two calls replace 2·N calls.
        old_hl = highlight_block(assigns.old, old_lines, language)
        new_hl = highlight_block(assigns.new, new_lines, language)

        {rows, _, _} = build_rows(diff_ops, old_hl, new_hl)

        assigns =
          assigns
          |> assign(:rows, rows)
          |> assign(:language, language)

        render_diff(assigns)
      end
    end
  end

  defp render_too_large(assigns, total_bytes) do
    assigns = assign(assigns, :total_bytes, total_bytes)

    ~H"""
    <div class="mt-1 rounded-lg overflow-hidden border border-zinc-200 dark:border-zinc-700/80 text-sm md:text-[13px] font-mono leading-snug">
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
      <div class="px-3 py-2 text-zinc-500 dark:text-zinc-400">
        Diff too large to render inline ({div(@total_bytes, 1024)} KB).
        <a :if={@link} href={@link} class="text-violet-600 dark:text-violet-400 hover:underline">
          Open file
        </a>
      </div>
    </div>
    """
  end

  defp render_diff(assigns) do
    ~H"""
    <div class="mt-1 rounded-lg overflow-hidden border border-zinc-200 dark:border-zinc-700/80 text-sm md:text-[13px] font-mono leading-snug">
      <div
        :if={@path}
        class="px-3 py-1 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-2"
      >
        <a
          :if={@link}
          href={@link}
          target="_blank"
          rel="noopener"
          class="min-w-0 flex-1 truncate text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
        >
          {@path}
        </a>
        <span :if={!@link} class="min-w-0 flex-1 truncate text-zinc-500 dark:text-zinc-400">
          {@path}
        </span>
        <%!-- Drill down: open the full file in a new tab (the diff here is height-
             capped + scrolls; this is the escape to the whole thing). --%>
        <a
          :if={@link}
          href={@link}
          target="_blank"
          rel="noopener"
          title="Open file in a new tab"
          class="flex-none p-0.5 text-zinc-400 hover:text-violet-500 dark:hover:text-violet-400 transition-colors"
        >
          <svg
            class="w-3 h-3"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
          >
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
        </a>
      </div>
      <%!-- Code-editor pane: lines DON'T wrap — they overflow and scroll
           horizontally — and the whole diff is height-capped so a big edit doesn't
           swallow the chat. Click the path/Open to see the full file. --%>
      <div class="overflow-auto max-h-80">
        <table class="w-full border-collapse highlight">
          <tbody>
            <tr :for={row <- @rows} class={row.bg}>
              <td class="select-none text-right pr-1 pl-2 py-0 text-zinc-500 dark:text-zinc-400 align-top w-[1%] whitespace-nowrap opacity-50">
                {row.old_num}
              </td>
              <td class="select-none text-right pr-2 py-0 text-zinc-500 dark:text-zinc-400 align-top w-[1%] whitespace-nowrap opacity-50">
                {row.new_num}
              </td>
              <%!-- phx-no-format + hugged tags: the cell is whitespace-pre, so any template
              indentation here renders as literal leading space on the diff line. --%>
              <td phx-no-format class={"pr-3 py-0 whitespace-pre #{row.text_class}"}><span class="select-none text-zinc-500 dark:text-zinc-400">{row.prefix}</span>{row.content}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # Pre-highlighted lines for one side, aligned 1:1 to `lines`. Falls back
  # to plain strings (HEEx auto-escapes) when there's no language, the
  # language is unsupported, or the highlighter's line count doesn't match
  # — so a highlighting hiccup degrades to a plain diff, never a broken one.
  defp highlight_block(text, lines, language) do
    case language && Syntax.highlight_lines(text, language) do
      hl when is_list(hl) and length(hl) == length(lines) ->
        hl

      _ ->
        Enum.map(lines, fn
          "" -> Phoenix.HTML.raw("&nbsp;")
          line -> line
        end)
    end
  end

  # Build row structs from myers diff operations, pulling each line's
  # rendered content from the pre-highlighted `old_hl` / `new_hl` lists
  # (consumed sequentially in lockstep with the diff ops).
  # Returns {rows, old_line_num, new_line_num}.
  defp build_rows(diff_ops, old_hl, new_hl) do
    {rows, old_n, new_n, _oh, _nh} =
      Enum.reduce(diff_ops, {[], 1, 1, old_hl, new_hl}, fn
        {:eq, lines}, {rows, old_n, new_n, oh, nh} ->
          n = length(lines)
          {content, nh} = Enum.split(nh, n)

          new_rows =
            Enum.with_index(content, fn c, i ->
              %{
                old_num: old_n + i,
                new_num: new_n + i,
                prefix: " ",
                content: c,
                bg: "",
                text_class: "text-zinc-700 dark:text-zinc-300"
              }
            end)

          {rows ++ new_rows, old_n + n, new_n + n, Enum.drop(oh, n), nh}

        {:del, lines}, {rows, old_n, new_n, oh, nh} ->
          n = length(lines)
          {content, oh} = Enum.split(oh, n)

          new_rows =
            Enum.with_index(content, fn c, i ->
              %{
                old_num: old_n + i,
                new_num: "",
                prefix: "-",
                content: c,
                bg: "bg-red-50/50 dark:bg-red-900/10",
                text_class: "text-red-700 dark:text-red-300"
              }
            end)

          {rows ++ new_rows, old_n + n, new_n, oh, nh}

        {:ins, lines}, {rows, old_n, new_n, oh, nh} ->
          n = length(lines)
          {content, nh} = Enum.split(nh, n)

          new_rows =
            Enum.with_index(content, fn c, i ->
              %{
                old_num: "",
                new_num: new_n + i,
                prefix: "+",
                content: c,
                bg: "bg-green-50/50 dark:bg-green-900/10",
                text_class: "text-green-700 dark:text-green-300"
              }
            end)

          {rows ++ new_rows, old_n, new_n + n, oh, nh}
      end)

    {rows, old_n, new_n}
  end
end
