defmodule Aural.Application do
  @moduledoc """
  OTP application for `:aural`. Deliberately does NOT start
  `Aural.Channel` — the host owns Channel's lifecycle because the
  Channel needs the host's `Phoenix.PubSub` running first, and
  there's no portable way to enforce that ordering from a dep.

  The host adds `Aural.Channel` to its supervision tree after the
  PubSub child:

      children = [
        {Phoenix.PubSub, name: MyApp.PubSub},
        Aural.Channel,
        # ...
      ]
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Aural.Supervisor)
  end
end
