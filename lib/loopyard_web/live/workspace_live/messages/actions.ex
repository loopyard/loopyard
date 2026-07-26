defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Actions do
  @moduledoc """
  The hover action buttons for a chat message — Copy (fetches raw source
  via the CopySource hook) and Open (raw permalink in a new tab).

  Split out of `LoopyardWeb.Live.WorkspaceLive.Messages` to keep that
  module under its size cap. `Messages` imports these so its `chat_msg/1`
  clauses render `<.copy_btn/>` / `<.open_btn/>` unchanged.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.Icon

  def copy_btn(assigns) do
    extra_class = assigns[:class] || ""
    assigns = assign(assigns, :extra_class, extra_class)

    ~H"""
    <button
      id={"copy-#{System.unique_integer([:positive])}"}
      phx-hook="CopySource"
      data-source={@raw_url}
      data-copy="fetch"
      class={"tap-target p-1 rounded-sm cursor-pointer text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 #{@extra_class}"}
      title="Copy"
    >
      <.icon name={:copy} class="w-3.5 h-3.5 copy-icon" />
      <.icon name={:check} class="w-3.5 h-3.5 check-icon hidden" />
    </button>
    """
  end

  def open_btn(assigns) do
    extra_class = assigns[:class] || ""
    assigns = assign(assigns, :extra_class, extra_class)

    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener"
      class={"tap-target p-1 rounded-sm text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 #{@extra_class}"}
      title="Open"
    >
      <.icon name={:external} class="w-3.5 h-3.5" />
    </a>
    """
  end
end
