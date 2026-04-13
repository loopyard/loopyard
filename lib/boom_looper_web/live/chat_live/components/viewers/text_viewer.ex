defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewer do
  @moduledoc "Renders text file content with line numbers and language hint."
  use Phoenix.Component

  alias BoomLooperWeb.Live.ChatLive.Components.Viewers.FileType

  attr :path, :string, required: true
  attr :content, :string, required: true

  def text_viewer(assigns) do
    language = FileType.language(assigns.path)
    lines = String.split(assigns.content, "\n")
    gutter_width = lines |> length() |> Integer.to_string() |> String.length()
    rendered = render_lines(lines, gutter_width)

    assigns =
      assigns
      |> assign(:language, language)
      |> assign(:line_count, length(lines))
      |> assign(:rendered, rendered)

    ~H"""
    <div class="flex flex-col max-h-[60vh] overflow-hidden">
      <div class="flex-none px-4 py-1.5 bg-zinc-100 dark:bg-zinc-800 flex items-center justify-between text-xs text-zinc-500 dark:text-zinc-400">
        <span>{@line_count} lines</span>
        <span :if={@language} class="font-mono">{@language}</span>
      </div>
      <div class="flex-1 overflow-auto">
        <pre class="text-sm font-mono leading-relaxed p-4 text-zinc-700 dark:text-zinc-300">{Phoenix.HTML.raw(@rendered)}</pre>
      </div>
    </div>
    """
  end

  defp render_lines(lines, gutter_width) do
    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      gutter = idx |> Integer.to_string() |> String.pad_leading(gutter_width)
      escaped = line |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      "#{gutter}  #{escaped}"
    end)
    |> Enum.join("\n")
  end
end
