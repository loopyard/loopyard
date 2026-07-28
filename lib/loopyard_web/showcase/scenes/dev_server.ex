defmodule LoopyardWeb.Showcase.Scenes.DevServer do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "dev-server",
    description:
      "The dev service's live log view: Rails booting, requests streaming, the " <>
        "port link in the header, and a previous run's crash output still on " <>
        "screen (the log buffer outlives the container)"

  alias LoopyardWeb.Showcase.Mock
  alias LoopyardWeb.Showcase.Scenes.WorkspaceFull

  @impl true
  def component, do: &LoopyardWeb.WorkspaceLive.render/1

  @impl true
  def assigns do
    Map.merge(WorkspaceFull.assigns(), %{
      live_action: :service,
      selected_service: "dev",
      service_logs: [],
      service_frames: frames()
    })
  end

  defp frames do
    [
      %{
        run: 1,
        frames: [
          f(-3600, "=> Booting Puma"),
          f(-3599, "=> Rails 7.2.1 application starting in development"),
          f(-3560, "* Listening on http://0.0.0.0:3000"),
          f(-1805, "\e[31mExiting\e[0m"),
          f(-1805, "config/initializers/payments.rb:4: missing STRIPE_KEY (KeyError)")
        ]
      },
      %{
        run: 2,
        frames: [
          f(-1740, "=> Booting Puma"),
          f(-1739, "=> Rails 7.2.1 application starting in development"),
          f(-1700, "* Listening on http://0.0.0.0:3000"),
          f(-240, "Started \e[32mGET\e[0m \"/cart\" for 172.19.0.1"),
          f(-240, "Processing by CartsController#show as HTML"),
          f(-239, "  Rendered carts/show.html.erb (Duration: 12.4ms)"),
          f(-239, "Completed \e[32m200 OK\e[0m in 21ms (Views: 13.1ms | ActiveRecord: 3.2ms)"),
          f(-31, "Started \e[32mPATCH\e[0m \"/cart/items/8\" for 172.19.0.1"),
          f(-31, "Processing by CartItemsController#update as TURBO_STREAM"),
          f(
            -30,
            "  \e[36mCartItem Update (1.8ms)\e[0m  UPDATE \"cart_items\" SET \"quantity\" = 3"
          ),
          f(-30, "Completed \e[32m200 OK\e[0m in 9ms (Views: 4.2ms | ActiveRecord: 2.9ms)")
        ]
      }
    ]
  end

  defp f(secs, text) do
    %{ts: DateTime.to_iso8601(Mock.at(secs)), text: text}
  end
end
