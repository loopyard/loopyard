defmodule HiveWeb.Presence do
  @moduledoc """
  Tracks connected viewers per agent for connection indicators.
  """
  use Phoenix.Presence,
    otp_app: :hive,
    pubsub_server: Hive.PubSub

  @doc """
  Returns the number of viewers for a given agent.
  """
  def viewer_count(agent_id) do
    "presence:agent:#{agent_id}"
    |> list()
    |> map_size()
  end

  @doc """
  Track a viewer for an agent. Uses the LiveView socket id as the key.
  """
  def track_viewer(pid, agent_id, socket_id) do
    track(pid, "presence:agent:#{agent_id}", socket_id, %{joined_at: System.system_time(:second)})
  end

  @doc """
  Untrack a viewer for an agent.
  """
  def untrack_viewer(pid, agent_id, socket_id) do
    untrack(pid, "presence:agent:#{agent_id}", socket_id)
  end

  @doc """
  Subscribe to presence diffs for an agent.
  """
  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(Hive.PubSub, "presence:agent:#{agent_id}")
  end

  @doc """
  Unsubscribe from presence diffs for an agent.
  """
  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(Hive.PubSub, "presence:agent:#{agent_id}")
  end
end
