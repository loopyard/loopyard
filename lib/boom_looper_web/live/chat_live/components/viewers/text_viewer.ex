defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewer do
  @moduledoc """
  Renders text file content with line numbers and syntax highlighting.

  Two modes:
  - **Code view** (default): syntax-highlighted with line numbers in an
    unselectable gutter. Copy-paste only grabs the content, not line numbers.
  - **Raw view**: plain text, no line numbers, no highlighting.

  Syntax highlighting is server-side via Makeup + makeup_syntect (Rust NIF).
  No JavaScript.
  """
  use Phoenix.Component

  alias BoomLooperWeb.Live.ChatLive.Components.Viewers.FileType

  attr :path, :string, required: true
  attr :content, :string, required: true
  attr :volume_name, :string, default: nil

  def text_viewer(assigns) do
    language = FileType.language(assigns.path)
    lines = String.split(assigns.content, "\n")

    assigns =
      assigns
      |> assign(:language, language)
      |> assign(:lines, lines)
      |> assign(:line_count, length(lines))

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
      <div class="flex-1 overflow-auto">
          <table class="text-sm font-mono leading-relaxed w-full border-collapse">
            <tbody>
              <tr :for={{line, idx} <- Enum.with_index(@lines, 1)}>
                <td class="select-none text-right pr-4 pl-4 py-0 text-zinc-400 dark:text-zinc-600 align-top w-[1%] whitespace-nowrap border-r border-zinc-200 dark:border-zinc-800">{idx}</td>
                <td class="pr-4 pl-4 py-0 whitespace-pre-wrap break-all">{highlight_line(line, @language)}</td>
              </tr>
            </tbody>
          </table>
      </div>
    </div>
    """
  end

  # Highlight a single line using Makeup. Returns a Phoenix.HTML.safe tuple.
  # Falls back to plain escaped text if the language isn't supported.
  defp highlight_line(line, nil), do: line
  defp highlight_line("", _language), do: Phoenix.HTML.raw("&nbsp;")

  defp highlight_line(line, language) do
    case makeup_highlight(line, language) do
      {:ok, highlighted} -> Phoenix.HTML.raw(highlighted)
      :error -> line
    end
  end

  defp makeup_highlight(line, language) do
    syntect_lang = syntect_language(language)

    try do
      tokens = MakeupSyntect.tokenize(line, language: syntect_lang)

      html =
        Makeup.Formatters.HTML.HTMLFormatter.format_as_iolist(tokens)
        |> IO.iodata_to_binary()
        # Strip the <pre><code> wrapper — we handle layout ourselves
        |> String.replace(~r/<pre[^>]*><code[^>]*>/, "")
        |> String.replace(~r/<\/code><\/pre>/, "")
        |> String.trim()

      {:ok, html}
    rescue
      _ -> :error
    end
  end

  # MakeupSyntect uses full language names (case-sensitive)
  defp syntect_language("elixir"), do: "Elixir"
  defp syntect_language("ruby"), do: "Ruby"
  defp syntect_language("javascript"), do: "JavaScript"
  defp syntect_language("typescript"), do: "TypeScript"
  defp syntect_language("python"), do: "Python"
  defp syntect_language("html"), do: "HTML"
  defp syntect_language("css"), do: "CSS"
  defp syntect_language("json"), do: "JSON"
  defp syntect_language("yaml"), do: "YAML"
  defp syntect_language("markdown"), do: "Markdown"
  defp syntect_language("shell"), do: "Bourne Again Shell (bash)"
  defp syntect_language("sql"), do: "SQL"
  defp syntect_language("go"), do: "Go"
  defp syntect_language("rust"), do: "Rust"
  defp syntect_language("dockerfile"), do: "Dockerfile"
  defp syntect_language("toml"), do: "TOML"
  defp syntect_language("xml"), do: "XML"
  defp syntect_language("c"), do: "C"
  defp syntect_language("cpp"), do: "C++"
  defp syntect_language("java"), do: "Java"
  defp syntect_language("swift"), do: "Swift"
  defp syntect_language("kotlin"), do: "Kotlin"
  defp syntect_language("erlang"), do: "Erlang"
  defp syntect_language(lang), do: lang
end
