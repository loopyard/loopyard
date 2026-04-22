defmodule BoomLooperWeb.Components.LogViewer do
  @moduledoc """
  Reusable function components for displaying streaming log output.

  Two variants:
  - `log_panel/1` — Full-height scrollable log viewer with TailScroll.
    Used for service log views and message live view.
  - `log_inline/1` — Compact inline log display with truncation.
    Used for build/command output in chat messages.

  Both support the "show existing content + stream new data" pattern.
  TailScroll auto-scrolls to the bottom unless the user has scrolled up.
  """
  use Phoenix.Component

  alias BoomLooperWeb.Components.Ansi

  @doc """
  Full-height scrollable log panel with auto-tail behavior.

  The `TailScroll` JS hook auto-scrolls on mount and update unless
  the user has scrolled up (in which case it pauses until they scroll
  back to the bottom).

  ## Attributes

    * `id` - Required. Unique DOM id for the element.
    * `content` - Required. The log text to display.
    * `class` - Optional. Additional CSS classes for the `<pre>` element.
  """
  attr :id, :string, required: true
  attr :content, :string, required: true
  attr :class, :string, default: ""

  def log_panel(assigns) do
    ansi_html = Ansi.to_html(assigns.content)
    assigns = assign(assigns, :ansi_html, ansi_html)

    ~H"""
    <pre
      id={@id}
      phx-hook="TailScroll"
      class={"flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300 #{@class}"}
    >{@ansi_html}</pre>
    """
  end

  @doc """
  Compact inline log display with status indicator and truncation.

  Shows a header bar with status dot + label, optional "open" link,
  and truncated output (last N lines). Used in chat for build/command output.

  ## Attributes

    * `content` - Required. Full log content.
    * `status` - Required. One of `:building`, `:done`, `:failed`.
    * `title` - Optional. Label for the header (defaults based on status).
    * `raw_url` - Optional. URL to full content in a new tab.
    * `max_lines` - Optional. Number of tail lines to show (default: 50).
  """
  attr :content, :string, required: true
  attr :status, :atom, required: true
  attr :title, :string, default: nil
  attr :raw_url, :string, default: nil
  attr :max_lines, :integer, default: 50

  def log_inline(assigns) do
    {label, dot_class} = case assigns.status do
      :building -> {assigns.title || "Running...", "bg-amber-400 animate-pulse"}
      :done -> {(assigns.title || "Command") <> " — done", "bg-green-500"}
      :failed -> {(assigns.title || "Command") <> " — failed", "bg-red-500"}
    end

    content = assigns.content || ""
    lines = String.split(content, "\n")
    truncated = length(lines) > assigns.max_lines
    display = if truncated, do: Enum.take(lines, -assigns.max_lines) |> Enum.join("\n"), else: content

    assigns = assign(assigns, label: label, dot_class: dot_class, display: display, truncated: truncated)

    ~H"""
    <div id={"log-wrap-#{System.unique_integer([:positive])}"} phx-hook="LogExpand" class="mt-2 mb-1 ml-10 rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{@dot_class}"}></div>
        <span class="text-xs font-medium text-zinc-500 dark:text-zinc-400">{@label}</span>
        <span :if={@truncated} class="text-[10px] text-zinc-400">... truncated</span>
        <div class="ml-auto flex items-center gap-2">
          <button type="button" data-expand class="text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors hidden">expand</button>
          <a :if={@raw_url} href={@raw_url} target="_blank" rel="noopener"
            class="text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors">
            open
          </a>
        </div>
      </div>
      <pre data-log-pre class={"px-3 py-2 text-xs font-mono text-zinc-800 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-950 whitespace-pre-wrap overflow-y-auto #{if @status == :building, do: "max-h-64", else: "max-h-32"}"}>{Ansi.to_html(@display)}</pre>
    </div>
    """
  end

  @doc """
  Interleaved multi-service log view with colored service name prefixes.

  ## Attributes

    * `logs` - Required. List of `%{name: String.t(), logs: String.t()}` maps.
  """
  @service_colors ~w(text-blue-400 text-green-400 text-yellow-400 text-pink-400 text-cyan-400 text-orange-400 text-violet-400 text-emerald-400)

  attr :logs, :list, required: true

  def log_multi_service(assigns) do
    indexed_logs =
      Enum.with_index(assigns.logs)
      |> Enum.map(fn {svc_log, idx} ->
        Map.put(svc_log, :color, Enum.at(@service_colors, rem(idx, length(@service_colors))))
      end)

    assigns = assign(assigns, :indexed_logs, indexed_logs)

    ~H"""
    <div class="flex-1 overflow-auto bg-zinc-950 px-4 py-3">
      <div :for={svc_log <- @indexed_logs}>
        <.log_service_block name={svc_log.name} logs={svc_log.logs} color={svc_log.color} />
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :logs, :string, required: true
  attr :color, :string, required: true

  defp log_service_block(assigns) do
    lines = String.split(assigns.logs, "\n", trim: true)
    padded_name = String.pad_leading(assigns.name, 12)
    assigns = assign(assigns, lines: lines, padded_name: padded_name)

    ~H"""
    <div :for={line <- @lines} class="flex text-xs font-mono leading-relaxed">
      <span class={"#{@color} w-36 text-right flex-none select-none"}>{@padded_name} |</span>
      <span class="text-zinc-300 ml-2 whitespace-pre-wrap break-all">{Ansi.to_html(line)}</span>
    </div>
    """
  end
end
