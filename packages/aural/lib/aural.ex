defmodule Aural do
  @moduledoc """
  Cerebral ambient audio bed for Phoenix apps. One synth + ffmpeg
  pipeline; fan-out to N HTTP listeners via the host's PubSub.

  Wiring is documented in `README.md`. The host must configure the
  PubSub server before any subscriber starts:

      config :aural, pubsub: MyApp.PubSub
  """

  @doc """
  PubSub server name configured by the host. Raises if unset — every
  Aural broadcast path needs a real PubSub on the host, and silently
  defaulting would hide misconfiguration until audio mysteriously
  fails to fan out.
  """
  def pubsub do
    Application.get_env(:aural, :pubsub) ||
      raise """
      Aural needs a PubSub server to broadcast on. Add this to the host's config:

          config :aural, pubsub: MyApp.PubSub

      and ensure {Phoenix.PubSub, name: MyApp.PubSub} is in the host's supervision tree.
      """
  end
end
