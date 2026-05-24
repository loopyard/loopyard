defmodule Aural.Application do
  @moduledoc """
  OTP application for `:aural`.

  Starts the `DynamicSupervisor` and `Registry` that channels live
  under — but does NOT pre-start any channels. The first call to
  `Aural.Channel.subscribe/1`, `.pick_track/2`, etc. lazily spawns
  a channel under the supervisor.

  Hosts add nothing to their supervision tree for `:aural` — just
  the dep + `config :aural, pubsub: MyApp.PubSub`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Aural.Channel.Registry},
      {DynamicSupervisor, name: Aural.Channel.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Aural.Supervisor)
  end
end
