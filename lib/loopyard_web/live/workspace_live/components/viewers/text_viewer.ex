defmodule LoopyardWeb.Live.WorkspaceLive.Components.Viewers.TextViewer do
  @moduledoc """
  Renders text file content with syntax highlighting and unselectable
  line numbers. "Raw" opens the file directly in the browser.

  Syntax highlighting is delegated to `Syntax.highlight/2` — this
  module only handles layout and line numbers.
  """
  use Phoenix.Component

  alias LoopyardWeb.Live.WorkspaceLive.Components.Viewers.{FileType, Syntax}

  attr :path, :string, required: true
  attr :content, :string, required: true
  attr :volume_name, :string, default: nil

  def text_viewer(assigns) do
    language = FileType.language(assigns.path)
    raw_lines = String.split(assigns.content, "\n")

    # Highlight the WHOLE file in ONE tokenize pass. The old code called
    # Syntax.highlight/2 per line, so a 1000-line file fired ~1000 MakeupSyntect
    # (Rust NIF) calls and took 10-18s synchronously in render — the page
    # appeared to "not load". highlight_lines/2 returns a list aligned to
    # String.split (nil → plain-text fallback).
    lines =
      case Syntax.highlight_lines(assigns.content, language) do
        nil ->
          Enum.map(raw_lines, fn
            "" -> Phoenix.HTML.raw("&nbsp;")
            l -> l
          end)

        highlighted ->
          highlighted
      end

    assigns =
      assigns
      |> assign(:language, language)
      |> assign(:lines, lines)
      |> assign(:line_count, length(raw_lines))

    ~H"""
    <div class="flex flex-col overflow-hidden h-full">
      <div class="flex-none px-4 py-1.5 bg-zinc-100 dark:bg-zinc-800 flex items-center justify-between text-xs text-zinc-500 dark:text-zinc-400">
        <div class="flex items-center gap-3">
          <span>{@line_count} lines</span>
          <span :if={@language} class="font-mono">{@language}</span>
        </div>
        <a
          :if={@volume_name}
          href={"/raw/#{@volume_name}/#{@path}"}
          target="_blank"
          rel="noopener"
          class="px-2 py-0.5 rounded text-xs hover:bg-zinc-200 dark:hover:bg-zinc-700"
        >
          Raw
        </a>
      </div>
      <div class="flex-1 overflow-auto highlight">
        <table class="text-sm font-mono leading-relaxed w-full border-collapse">
          <tbody>
            <%!-- phx-no-format + hugged tags: the code cell is whitespace-pre-wrap, so any
              template indentation/newlines around the content render as literal leading
              space (pushing code right) and blank lines (making every row tall). --%>
            <tr :for={{line, idx} <- Enum.with_index(@lines, 1)}>
              <td
                phx-no-format
                class="select-none text-right pr-4 pl-4 py-0 text-zinc-500 dark:text-zinc-400 align-top w-[1%] whitespace-nowrap border-r border-zinc-200 dark:border-zinc-800"
              >{idx}</td>
              <td phx-no-format class="pr-4 pl-4 py-0 whitespace-pre-wrap break-all">{line}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
