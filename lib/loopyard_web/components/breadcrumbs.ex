defmodule LoopyardWeb.Components.Breadcrumbs do
  @moduledoc """
  The one breadcrumb renderer. Every page uses this — not an inline
  variant — so navigating up the chain produces zero visual shift.

  Pass `crumbs` as a list of `{label, path_or_nil}` tuples. `nil` path
  marks the current page (rendered as a non-link span with
  aria-current="page"). A non-nil path always renders as a link —
  including for the last crumb, so a caller can opt the trailing
  segment into being clickable (e.g. "back to workspace overview"
  when viewing a sub-route). All crumbs render with identical font
  weight / size / metrics so navigation never causes a 1-2 px jump.
  """

  use Phoenix.Component

  attr :crumbs, :list, required: true
  attr :class, :string, default: ""

  def breadcrumbs(assigns) do
    # Below sm we hide the trail and show only the current page — so there's no
    # visible way UP. Add a back arrow to the parent (the crumb right before the
    # current one, if it links somewhere) that shows on mobile only.
    parent_path =
      case Enum.reverse(assigns.crumbs) do
        [_current, {_label, path} | _] when is_binary(path) -> path
        _ -> nil
      end

    assigns = assign(assigns, :parent_path, parent_path)

    ~H"""
    <nav aria-label="Breadcrumb" class={["flex items-center min-w-0", @class]}>
      <ol class="flex items-center gap-1.5 min-w-0 list-none p-0 m-0">
        <li :if={@parent_path} class="flex sm:hidden flex-none">
          <.link
            navigate={@parent_path}
            aria-label="Back"
            class="focus-ring inline-flex items-center justify-center w-9 h-9 -ml-2 rounded-md text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
          >
            <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
              <path
                fill-rule="evenodd"
                d="M11.78 5.22a.75.75 0 0 1 0 1.06L8.06 10l3.72 3.72a.75.75 0 1 1-1.06 1.06l-4.25-4.25a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Z"
                clip-rule="evenodd"
              />
            </svg>
          </.link>
        </li>
        <%= for {{label, path}, idx} <- Enum.with_index(@crumbs) do %>
          <%!-- On mobile show only the current page; the full trail returns at sm+
               so it stops truncating into ellipsis soup against the nav. Hierarchy
               is by COLOR (ancestors muted, current page solid) — same font weight
               throughout so navigating up never shifts the layout by a pixel. --%>
          <li class={[
            "items-center gap-1.5 min-w-0",
            if(idx == length(@crumbs) - 1, do: "flex", else: "hidden sm:flex")
          ]}>
            <%= if path do %>
              <.link
                navigate={path}
                class="focus-ring text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 transition-colors truncate rounded"
              >
                {label}
              </.link>
            <% else %>
              <span
                aria-current={if idx == length(@crumbs) - 1, do: "page"}
                class="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate"
              >
                {label}
              </span>
            <% end %>
            <svg
              :if={idx != length(@crumbs) - 1}
              aria-hidden="true"
              viewBox="0 0 20 20"
              fill="currentColor"
              class="w-4 h-4 flex-none text-zinc-300 dark:text-zinc-600"
            >
              <path
                fill-rule="evenodd"
                d="M8.22 5.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L11.94 10 8.22 6.28a.75.75 0 0 1 0-1.06Z"
                clip-rule="evenodd"
              />
            </svg>
          </li>
        <% end %>
      </ol>
    </nav>
    """
  end
end
