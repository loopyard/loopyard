defmodule LoopyardWeb.Showcase.Scenes.SshConsole do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "ssh-console",
    description:
      "The shared workspace terminal in the browser, with the SSH command in " <>
        "the header for reaching the exact same session from a real terminal"

  alias LoopyardWeb.Showcase.Scenes.WorkspaceFull

  @impl true
  def component, do: &LoopyardWeb.WorkspaceLive.render/1

  @impl true
  def assigns do
    Map.merge(WorkspaceFull.assigns(), %{
      live_action: :console,
      selected_service: "workspace",
      console_container: "loopyard-checkout-fix-work",
      console_static_lines: [
        "maya@checkout-fix:/workspace$ bin/rails console",
        "Loading development environment (Rails 7.2.1)",
        "storefront(dev)> Cart.order(:updated_at).last.total_cents",
        "=> 4899",
        "storefront(dev)> exit",
        "maya@checkout-fix:/workspace$ git log --oneline -2",
        "f3a91c2 Cart total renders once, from the server payload",
        "8be04d7 Debounce quantity stepper input",
        "maya@checkout-fix:/workspace$ █"
      ]
    })
  end
end
