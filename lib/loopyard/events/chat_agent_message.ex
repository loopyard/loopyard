defmodule Loopyard.Events.ChatAgentMessage do
  @moduledoc """
  Publisher module for the per-agent `"chat_agent:{id}"` PubSub topic.

  Move #2 of plans/coordination-hardening.md. All message + streaming output
  events for an individual chat agent flow through this module. The topic
  name includes the agent id so subscribers only receive events for the
  agent they care about (workspace LV, message LV).
  """

  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.ChatAgentMessage.{Message, TextDelta, StreamOutput}

  @events [Message, TextDelta, StreamOutput]

  @doc "List of every event module published on this topic."
  def events, do: @events

  @doc "Topic name for a given agent id."
  def topic(agent_id), do: "chat_agent:#{agent_id}"

  @doc "Subscribe the current process to a specific agent's topic."
  def subscribe(agent_id), do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic(agent_id))

  @doc "Unsubscribe the current process from a specific agent's topic."
  def unsubscribe(agent_id), do: Phoenix.PubSub.unsubscribe(Loopyard.PubSub, topic(agent_id))

  @doc """
  Broadcast an event to the agent's per-id topic. The event struct carries
  its own `:agent_id` so consumers that land the message on the wrong topic
  can still validate. Topic is derived from the struct's id.
  """
  def publish(%Message{agent_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%TextDelta{agent_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%StreamOutput{agent_id: id} = e) when is_binary(id), do: bcast(id, e)

  defp bcast(agent_id, %mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: topic(agent_id), event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, topic(agent_id), e)
  end
end

defmodule Loopyard.Events.ChatAgentMessage.Subscriber do
  @moduledoc """
  Behaviour for views that subscribe to a specific agent's
  `"chat_agent:{id}"` topic. Move #3 of plans/coordination-hardening.md.
  """

  alias Loopyard.Events.ChatAgentMessage

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_message(ChatAgentMessage.Message.t(), socket) :: result
  @callback on_text_delta(ChatAgentMessage.TextDelta.t(), socket) :: result
  @callback on_stream_output(ChatAgentMessage.StreamOutput.t(), socket) :: result

  # See plans/post-migration-audit.md MEDIUM #5 — no @optional_callbacks.
end
