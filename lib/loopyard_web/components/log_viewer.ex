defmodule LoopyardWeb.Components.LogViewer do
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

  alias LoopyardWeb.Components.Ansi

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
      class={"flex-1 px-4 py-3 text-xs md:text-[13px] font-mono leading-snug overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-zinc-300 #{@class}"}
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
  attr :started, :any, default: nil
  attr :exit_code, :integer, default: nil

  def log_inline(assigns) do
    {status_label, dot_class} =
      case assigns.status do
        :building -> {"Running", "bg-amber-400 animate-pulse"}
        :done -> {"Done", "bg-green-500"}
        :failed -> {"Failed", "bg-red-500"}
      end

    content = assigns.content || ""
    lines = String.split(content, "\n")
    truncated = length(lines) > assigns.max_lines

    display =
      if truncated, do: Enum.take(lines, -assigns.max_lines) |> Enum.join("\n"), else: content

    assigns =
      assign(assigns,
        status_label: status_label,
        dot_class: dot_class,
        display: display,
        truncated: truncated,
        command: assigns.title
      )

    ~H"""
    <div
      id={"log-wrap-#{System.unique_integer([:positive])}"}
      phx-hook="LogExpand"
      class="mt-2 mb-1 rounded-lg border border-zinc-200 dark:border-zinc-800 overflow-hidden bg-zinc-100 dark:bg-zinc-950"
    >
      <%!-- Terminal title bar: the COMMAND is the title (one line, truncated — long
           commands don't wrap and wreck the layout; hover for the full text). It
           finalizes with a green `exit 0` or red `exit N`. The output streams in
           the body below; the command is NOT repeated there. --%>
      <div class="flex items-center gap-2 px-3 py-1.5 bg-zinc-50 dark:bg-zinc-900/60 border-b border-zinc-200 dark:border-zinc-800">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{@dot_class}"}></div>
        <span
          title={@command}
          class="text-sm md:text-[13px] font-mono text-zinc-500 dark:text-zinc-400 truncate min-w-0 flex-1"
        >
          {@command || @status_label}
        </span>
        <span
          :if={@status == :building && elapsed_since(@started)}
          id={"elapsed-#{elapsed_since(@started)}"}
          phx-hook="Elapsed"
          phx-update="ignore"
          data-since={elapsed_since(@started)}
          class="text-xs tabular-nums text-amber-500 dark:text-amber-400 flex-none"
        >
          0s
        </span>
        <span
          :if={@status != :building}
          class={[
            "text-xs font-semibold tabular-nums flex-none",
            if(@status == :done,
              do: "text-green-600 dark:text-green-400",
              else: "text-red-500 dark:text-red-400"
            )
          ]}
        >
          {exit_label(@status, @exit_code)}
        </span>
        <span :if={@truncated} class="text-xs text-zinc-400 flex-none">… truncated</span>
        <div class="flex items-center gap-1 flex-none">
          <button
            type="button"
            data-expand
            class="p-1 text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors hidden"
            title="Show full output"
          >
            <%!-- Chevron-down = "show more". Was a ✗ (close) glyph, which read as
                 an error/cancel right next to the exit status — this is an
                 expand affordance, not a dismiss. --%>
            <svg
              class="w-3.5 h-3.5"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
            >
              <path d="M4.22 6.22a.75.75 0 0 1 1.06 0L8 8.94l2.72-2.72a.75.75 0 1 1 1.06 1.06l-3.25 3.25a.75.75 0 0 1-1.06 0L4.22 7.28a.75.75 0 0 1 0-1.06Z" />
            </svg>
          </button>
          <button
            :if={@raw_url}
            id={"copy-log-#{System.unique_integer([:positive])}"}
            phx-hook="CopySource"
            data-source={@raw_url}
            data-copy="fetch"
            class="p-1 text-zinc-400 hover:text-zinc-300 transition-colors cursor-pointer"
            title="Copy"
          >
            <svg
              class="w-3 h-3 copy-icon"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
            >
              <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 1 .439 1.061V9.5A1.5 1.5 0 0 1 12 11V8.621a3 3 0 0 0-.879-2.121L9 4.379A3 3 0 0 0 6.879 3.5H5.5Z" />
              <path d="M4 5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 14h5a1.5 1.5 0 0 0 1.5-1.5V8.621a1.5 1.5 0 0 0-.44-1.06L7.94 5.439A1.5 1.5 0 0 0 6.878 5H4Z" />
            </svg>
            <svg
              class="w-3 h-3 check-icon hidden"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
            >
              <path
                fill-rule="evenodd"
                d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z"
                clip-rule="evenodd"
              />
            </svg>
          </button>
          <a
            :if={@raw_url}
            href={@raw_url}
            target="_blank"
            rel="noopener"
            class="p-1 text-zinc-400 hover:text-zinc-300 transition-colors"
            title="Open"
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
      </div>
      <%!-- Output reads like a code-editor pane: no wrap (lines overflow and scroll
           horizontally), height-capped so a long log doesn't swallow the chat —
           click (LogExpand) to open the full thing. --%>
      <pre
        data-log-pre
        class={[
          "text-xs md:text-[13px] font-mono leading-snug text-zinc-800 dark:text-zinc-300 bg-zinc-100 dark:bg-zinc-950 whitespace-pre overflow-auto px-3 py-2",
          if(@status == :building, do: "max-h-64", else: "max-h-32")
        ]}
      >{Ansi.to_html(@display)}</pre>
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
    <div :for={line <- @lines} class="flex text-xs font-mono leading-snug">
      <span class={"#{@color} w-36 text-right flex-none select-none"}>{@padded_name} |</span>
      <span class="text-zinc-300 ml-2 whitespace-pre-wrap break-all">{Ansi.to_html(line)}</span>
    </div>
    """
  end

  # Unix-ms start time for the client-side Elapsed hook, which ticks the
  # counter every second from this anchor (no server round-trips). Tolerant
  # of a missing/odd timestamp — returns nil so the timer simply doesn't show.
  defp elapsed_since(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp elapsed_since(_), do: nil

  # The finalized status badge: green `exit 0` on success, red `exit N` when we
  # captured the code (streamed exec/build path), else a plain red `failed`. The
  # ACP tool-result path only reports pass/fail (no numeric code), so `failed`
  # is the honest label there — never a cryptic `✗` that reads like a close icon.
  defp exit_label(:done, _), do: "exit 0"
  defp exit_label(:failed, code) when is_integer(code), do: "exit #{code}"
  defp exit_label(:failed, _), do: "failed"
  defp exit_label(_, _), do: ""
end
