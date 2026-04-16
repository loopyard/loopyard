defmodule BoomLooperWeb.Components.Breadcrumbs do
  @moduledoc """
  The one breadcrumb renderer. Every page uses this — not an inline
  variant — so navigating up the chain produces zero visual shift.

  Pass `crumbs` as a list of `{label, path_or_nil}` tuples. `nil` path
  marks the current page (rendered as non-link). All crumbs render with
  identical font weight / size / metrics, which is the only way to
  avoid a 1-2 px jump when the current crumb becomes a link and vice
  versa across navigations.
  """

  use Phoenix.Component

  attr :crumbs, :list, required: true
  attr :class, :string, default: ""

  def breadcrumbs(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" class={["flex items-center gap-2 min-w-0", @class]}>
      <ol class="flex items-center gap-2 min-w-0 list-none p-0 m-0">
        <%= for {{label, path}, idx} <- Enum.with_index(@crumbs) do %>
          <li class="flex items-center gap-2 min-w-0">
            <%= if path && idx != length(@crumbs) - 1 do %>
              <.link
                navigate={path}
                class="focus-ring text-sm font-medium text-zinc-700 dark:text-zinc-200 hover:text-violet-600 dark:hover:text-violet-400 transition-colors truncate rounded"
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
            <span
              :if={idx != length(@crumbs) - 1}
              aria-hidden="true"
              class="text-zinc-300 dark:text-zinc-600 select-none"
            >
              /
            </span>
          </li>
        <% end %>
      </ol>
    </nav>
    """
  end
end
