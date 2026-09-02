defmodule LoopyardWeb.Live.WorkspaceLive.Messages.AttachmentChip do
  @moduledoc """
  One attachment on a human prompt band (see `Loopyard.Attachments`): an image
  is its own thumbnail, anything else a named chip.
  """
  use Phoenix.Component
  import LoopyardWeb.Components.Icon

  # One attachment on a human prompt: an image is its own thumbnail (click →
  # full size in a new tab), anything else is a named chip. Without a URL
  # (workspace unknown) the name still shows.
  attr :att, :map, required: true
  attr :url, :string, default: nil

  def chip(assigns) do
    assigns = assign(assigns, :image?, Loopyard.Attachments.image?(assigns.att))

    ~H"""
    <a
      :if={@url}
      href={@url}
      target="_blank"
      rel="noopener"
      title={"#{Loopyard.Attachments.display_name(@att)} · #{Loopyard.Attachments.human_size(@att.size)}"}
      class="focus-ring block rounded-sm border border-violet-300/60 dark:border-violet-400/25 bg-white/70 dark:bg-black/20 overflow-hidden hover:border-violet-500 transition-colors"
    >
      <%!-- onerror: the file can vanish from the volume (an agent's rm, a
      fresh clone) — a broken-image icon says nothing, the name chip does. --%>
      <img
        :if={@image?}
        src={@url}
        alt={Loopyard.Attachments.display_name(@att)}
        loading="lazy"
        class="block h-24 w-auto max-w-[220px] object-cover"
        onerror="this.hidden = true; this.nextElementSibling.hidden = false"
      />
      <span
        hidden={@image?}
        class="inline-flex items-center gap-1.5 px-2 py-1.5 text-body text-zinc-700 dark:text-zinc-200"
      >
        <.icon name={:paper_clip} class="w-3.5 h-3.5 flex-none text-violet-500" />
        {Loopyard.Attachments.display_name(@att)}
      </span>
    </a>
    <span
      :if={!@url}
      class="inline-flex items-center gap-1.5 px-2 py-1.5 text-body text-zinc-600 dark:text-zinc-300 rounded-sm border border-violet-300/60 dark:border-violet-400/25"
    >
      <.icon name={:paper_clip} class="w-3.5 h-3.5 flex-none text-violet-500" />
      {Loopyard.Attachments.display_name(@att)}
    </span>
    """
  end
end
