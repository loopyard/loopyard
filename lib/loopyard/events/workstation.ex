defmodule Loopyard.Events.Workstation do
  @moduledoc """
  Publisher for the per-workstation `"workstation:<id>"` PubSub topic.

  Credentials arrive from OUTSIDE the browser — a `curl -T` from the user's Mac
  pushing an env var or an integration file. Without a broadcast the integration
  page can only learn about that on mount, so a successful push left the badge
  reading "Not connected" until a manual re-check. Per-workstation topic because
  every subscriber is already scoped to one identity.

  Per the PubSub boundary rule this is the ONLY place these broadcasts happen;
  every subscriber implements the `Subscriber` behaviour with an explicit
  callback (no `@optional_callbacks`).
  """
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.Workstation.CredentialsChanged

  @events [CredentialsChanged]

  def events, do: @events

  def topic(id) when is_binary(id), do: "workstation:" <> id

  def subscribe(id) when is_binary(id),
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic(id))

  def publish(%CredentialsChanged{workstation_id: id} = e) when is_binary(id) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: topic(id), event: CredentialsChanged})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, topic(id), e)
  end

  def publish(%CredentialsChanged{}), do: :ok
end
