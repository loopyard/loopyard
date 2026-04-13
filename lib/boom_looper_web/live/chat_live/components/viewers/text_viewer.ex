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
  attr :mode, :atom, default: :code

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
        <div class="flex items-center gap-2">
          <button
            phx-click="set_file_mode"
            phx-value-mode={if @mode == :code, do: "raw", else: "code"}
            class={"px-2 py-0.5 rounded text-xs #{if @mode == :raw, do: "bg-zinc-200 dark:bg-zinc-700 text-zinc-700 dark:text-zinc-300", else: "hover:bg-zinc-200 dark:hover:bg-zinc-700"}"}
          >
            Raw
          </button>
        </div>
      </div>
      <div class="flex-1 overflow-auto">
        <%= if @mode == :raw do %>
          <pre class="text-sm font-mono leading-relaxed p-4 text-zinc-700 dark:text-zinc-300 whitespace-pre-wrap">{@content}</pre>
        <% else %>
          <table class="text-sm font-mono leading-relaxed w-full border-collapse">
            <tbody>
              <tr :for={{line, idx} <- Enum.with_index(@lines, 1)}>
                <td class="select-none text-right pr-4 pl-4 py-0 text-zinc-400 dark:text-zinc-600 align-top w-[1%] whitespace-nowrap border-r border-zinc-200 dark:border-zinc-800">{idx}</td>
                <td class="pr-4 pl-4 py-0 whitespace-pre-wrap break-all">{highlight_line(line, @language)}</td>
              </tr>
            </tbody>
          </table>
        <% end %>
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
    # makeup_syntect uses file extensions to identify languages
    ext = language_to_ext(language)

    try do
      highlighted = Makeup.highlight(line, lexer: MakeupSyntect, lexer_options: [extension: ext])
      # Makeup wraps in <pre><code> — strip those, we handle our own layout
      stripped =
        highlighted
        |> String.replace(~r/<pre[^>]*><code[^>]*>/, "")
        |> String.replace(~r/<\/code><\/pre>/, "")
        |> String.trim()

      {:ok, stripped}
    rescue
      _ -> :error
    end
  end

  # Map our language names to file extensions that syntect recognizes
  defp language_to_ext("elixir"), do: "ex"
  defp language_to_ext("ruby"), do: "rb"
  defp language_to_ext("javascript"), do: "js"
  defp language_to_ext("typescript"), do: "ts"
  defp language_to_ext("python"), do: "py"
  defp language_to_ext("html"), do: "html"
  defp language_to_ext("css"), do: "css"
  defp language_to_ext("json"), do: "json"
  defp language_to_ext("yaml"), do: "yml"
  defp language_to_ext("markdown"), do: "md"
  defp language_to_ext("shell"), do: "sh"
  defp language_to_ext("sql"), do: "sql"
  defp language_to_ext("go"), do: "go"
  defp language_to_ext("rust"), do: "rs"
  defp language_to_ext("dockerfile"), do: "Dockerfile"
  defp language_to_ext("toml"), do: "toml"
  defp language_to_ext("xml"), do: "xml"
  defp language_to_ext("c"), do: "c"
  defp language_to_ext("cpp"), do: "cpp"
  defp language_to_ext("java"), do: "java"
  defp language_to_ext("swift"), do: "swift"
  defp language_to_ext("kotlin"), do: "kt"
  defp language_to_ext(lang), do: lang
end
