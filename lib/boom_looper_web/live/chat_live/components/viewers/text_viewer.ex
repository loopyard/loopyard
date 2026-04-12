defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewer do
  @moduledoc "Renders text file content with line numbers and language hint."
  use Phoenix.Component

  alias BoomLooperWeb.Live.ChatLive.Components.Viewers.FileType

  attr :path, :string, required: true
  attr :content, :string, required: true

  def text_viewer(assigns) do
    language = FileType.language(assigns.path)
    lines = String.split(assigns.content, "\n")
    line_count = length(lines)
    gutter_width = line_count |> Integer.to_string() |> String.length()

    assigns =
      assigns
      |> assign(:language, language)
      |> assign(:lines, lines)
      |> assign(:gutter_width, gutter_width)

    ~H"""
    <div class="flex flex-col max-h-[60vh] overflow-hidden">
      <div class="flex-none px-4 py-1.5 bg-zinc-100 dark:bg-zinc-800 flex items-center justify-between text-xs text-zinc-500 dark:text-zinc-400">
        <span>{length(@lines)} lines</span>
        <span :if={@language} class="font-mono">{@language}</span>
      </div>
      <div class="flex-1 overflow-auto">
        <pre class="text-sm font-mono leading-relaxed"><code><%= for {line, idx} <- Enum.with_index(@lines, 1) do %><span class="inline-block text-right text-zinc-400 dark:text-zinc-600 select-none mr-4" style={"width: #{@gutter_width}ch"}>{idx}</span>{escape(line)}
<% end %></code></pre>
      </div>
    </div>
    """
  end

  defp escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
