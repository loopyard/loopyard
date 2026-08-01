defmodule LoopyardWeb.Components.Workstation do
  @moduledoc """
  Shared function components for the Workstation pages (hub, console, image, env,
  and the per-tool integration page). Extracted so every screen renders the same
  section headings, command boxes, list rows, status pills, and buttons — one
  source of truth for the look.

  Imported on-demand by `WorkstationLive` and `WorkstationToolLive` (not blanket-
  imported), per the house convention for page-specific components.
  """
  use Phoenix.Component

  @doc """
  A page sub-section: a small heading, an optional one-line hint, then content.
  The consistent unit every Workstation screen is built from.
  """
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class="space-y-2">
      <div>
        <h2 class="text-sm font-medium text-zinc-800 dark:text-zinc-100">{@title}</h2>
        <p :if={@hint} class="text-xs text-zinc-500 dark:text-zinc-400 leading-relaxed">
          {@hint}
        </p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "A bordered, divided list. Fill it with `nav_row`s."
  slot :inner_block, required: true

  def nav_list(assigns) do
    ~H"""
    <div class=" border border-zinc-200 dark:border-zinc-800 divide-y divide-zinc-100 dark:divide-zinc-800 overflow-hidden">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A navigable row inside a `nav_list`: a title, an optional description, an
  optional `:trailing` slot (e.g. a status pill), and a trailing chevron.
  """
  attr :navigate, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, default: nil
  slot :trailing

  def nav_row(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center justify-between gap-3 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
    >
      <div class="min-w-0">
        <div class="text-sm font-medium text-zinc-800 dark:text-zinc-100">{@title}</div>
        <div :if={@desc} class="text-xs text-zinc-500 dark:text-zinc-400 truncate">{@desc}</div>
      </div>
      <span class="flex items-center gap-2 flex-none text-xs">
        {render_slot(@trailing)}
        <.chevron />
      </span>
    </.link>
    """
  end

  @doc "A connect-status pill: `:connected | :not_connected | :checking`."
  attr :status, :atom, required: true

  def status_pill(%{status: :connected} = assigns) do
    ~H"""
    <span class="flex-none text-xs font-medium rounded-full px-2.5 py-1 bg-emerald-100 dark:bg-emerald-950/50 text-emerald-700 dark:text-emerald-400">
      Connected
    </span>
    """
  end

  def status_pill(%{status: :checking} = assigns) do
    ~H"""
    <span class="flex-none text-xs rounded-full px-2.5 py-1 bg-zinc-100 dark:bg-zinc-800 text-zinc-400 animate-pulse">
      Checking…
    </span>
    """
  end

  def status_pill(assigns) do
    ~H"""
    <span class="flex-none text-xs font-medium rounded-full px-2.5 py-1 bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400">
      Not connected
    </span>
    """
  end

  @doc """
  A dark, copyable command box: a `<pre>` with the command + a Copy button wired
  to the `Clip` JS hook. `id` must be unique on the page.

  Sizing is mobile-first and shrinks at `md:` — Copy is the primary action on a
  phone (where you're least likely to be able to select the text by hand), so it
  clears the ~44px finger target there and tightens up on desktop, where a
  cursor is precise and the button should stop shouting.

  The command WRAPS on mobile rather than scrolling off-screen. These commands
  pipe into `sh`, and a developer who can't read what they're about to run is
  right not to trust it — height is the cheaper cost. Desktop has the width to
  scroll instead.
  """
  attr :id, :string, required: true
  attr :command, :string, required: true

  def command_box(assigns) do
    ~H"""
    <div class="flex items-stretch gap-2">
      <pre class="flex-1 min-w-0 whitespace-pre-wrap break-all md:whitespace-pre md:break-normal md:overflow-x-auto rounded-sm bg-zinc-900 dark:bg-zinc-950 text-zinc-100 text-xs leading-relaxed font-mono px-3 py-3 md:py-2.5 ring-1 ring-zinc-800">{@command}</pre>
      <button
        id={@id}
        type="button"
        phx-hook="Clip"
        data-label="Copy"
        data-copy={@command}
        class="focus-ring flex-none self-stretch md:self-start rounded-sm bg-zinc-900 hover:bg-zinc-700 text-white dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white px-4 md:px-3.5 py-3 md:py-2.5 text-sm md:text-xs font-medium transition-colors"
      >
        Copy
      </button>
    </div>
    """
  end

  @doc """
  A button, consistent across the Workstation pages.

  * `:primary` — solid violet (the page's main action: Save & Rebuild).
  * `:secondary` — outline (Save, Add — quieter confirmations).

  Pass `type="submit"` for forms; any other attrs (`name`, `value`, `disabled`,
  `phx-click`, …) pass through.
  """
  attr :variant, :atom, default: :secondary, values: [:primary, :secondary]
  attr :type, :string, default: "button"
  attr :class, :string, default: ""
  attr :rest, :global, include: ~w(name value disabled form)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button type={@type} class={[button_class(@variant), @class]} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_class(:primary),
    do:
      "focus-ring inline-flex items-center justify-center gap-1.5 rounded-sm bg-violet-600 hover:bg-violet-700 disabled:opacity-60 text-white px-4 py-2 text-sm font-semibold transition-colors"

  defp button_class(:secondary),
    do:
      "focus-ring inline-flex items-center justify-center rounded-sm border border-zinc-300 dark:border-zinc-600 px-4 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-60 transition-colors"

  @doc "A small Restart button — recreates the workstation container ($HOME kept)."
  attr :restarting, :boolean, required: true
  attr :class, :string, default: ""

  def restart_button(assigns) do
    ~H"""
    <button
      phx-click="restart_machine"
      disabled={@restarting}
      title="Recreate the workstation container (your $HOME / logins are kept)"
      class={[
        "focus-ring inline-flex items-center gap-1.5 rounded-sm px-2.5 py-1.5 text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-50 transition-colors",
        @class
      ]}
    >
      <svg
        class={["w-3.5 h-3.5", @restarting && "animate-spin"]}
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        stroke-width="2"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
        />
      </svg>
      {if @restarting, do: "Restarting…", else: "Restart"}
    </button>
    """
  end

  @doc "The trailing chevron used on nav rows."
  def chevron(assigns) do
    ~H"""
    <svg
      class="w-3.5 h-3.5 flex-none text-zinc-300 dark:text-zinc-600"
      viewBox="0 0 12 12"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M4.5 3 7.5 6 4.5 9"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end
end
