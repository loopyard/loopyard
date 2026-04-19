defmodule BoomLooper.Events.ChatAgentMessage do
  @moduledoc """
  Publisher module for the per-agent `"chat_agent:{id}"` PubSub topic.

  Move #2 of plans/coordination-hardening.md. All message + streaming output
  events for an individual chat agent flow through this module. The topic
  name includes the agent id so subscribers only receive events for the
  agent they care about (workspace LV, message LV).
  """

  @telemetry [:boom_looper, :events, :publish]

  # One completed chat message appended to the agent's log. `msg` is the
  # message map with at least `:role`, `:content`, `:timestamp`, `:id`.
  defmodule Message, do: defstruct([:agent_id, :msg])

  # A streaming text chunk from Claude. Not persisted; UI uses it to
  # render "typing" output between full `Message` events.
  defmodule TextDelta, do: defstruct([:agent_id, :text])

  # Streaming command output (docker compose build, exec_stream, etc.)
  # attached to a streaming-message id. `title` is a short label.
  defmodule StreamOutput, do: defstruct([:agent_id, :data, :title, :msg_id])

  @events [Message, TextDelta, StreamOutput]

  @doc "List of every event module published on this topic."
  def events, do: @events

  @doc "Topic name for a given agent id."
  def topic(agent_id), do: "chat_agent:#{agent_id}"

  @doc "Subscribe the current process to a specific agent's topic."
  def subscribe(agent_id), do: Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic(agent_id))

  @doc "Unsubscribe the current process from a specific agent's topic."
  def unsubscribe(agent_id), do: Phoenix.PubSub.unsubscribe(BoomLooper.PubSub, topic(agent_id))

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
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, topic(agent_id), e)
  end
end

defmodule BoomLooper.Events.ChatAgentMessage.Subscriber do
  @moduledoc """
  Behaviour for views that subscribe to a specific agent's
  `"chat_agent:{id}"` topic. Move #3 of plans/coordination-hardening.md.
  """

  alias BoomLooper.Events.ChatAgentMessage

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_message(ChatAgentMessage.Message.t(), socket) :: result
  @callback on_text_delta(ChatAgentMessage.TextDelta.t(), socket) :: result
  @callback on_stream_output(ChatAgentMessage.StreamOutput.t(), socket) :: result

  # See plans/post-migration-audit.md MEDIUM #5 — no @optional_callbacks.
end
