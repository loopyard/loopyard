defmodule LoopyardWeb.Live.WorkspaceLive.Composer do
  @moduledoc """
  The composer's send, server-side: hand a (possibly attachment-annotated)
  message to the selected agent and produce the `{:reply, %{ok: ...}}` the
  `ChatForm` hook keys the input-clear on. Extracted from `WorkspaceLive`'s
  `send_message` handler; the LiveView keeps only the routing (edit-in-place
  vs. attachments-then-send).
  """

  alias Loopyard.ChatAgent
  alias LoopyardWeb.Live.WorkspaceLive.{AgentEvents, AgentLifecycle}

  # The send proper (after attachments are in the volume): durability-confirmed
  # enqueue → wake-and-enqueue fallback → ONE note channel on failure.
  def deliver(socket, message) do
    # Don't add optimistically — let PubSub broadcast handle it for ALL viewers.
    # This ensures multiplayer: every viewer (including the sender) sees the
    # message via the same path.
    #
    # DURABILITY-CONFIRMED: use enqueue_message (a call), not send_message (a
    # cast). We only reply ok: true — the signal the ChatForm hook waits on
    # before clearing the box — once the agent has actually RECEIVED and stored
    # the message. If its GenServer is down, DON'T bounce an error at the user:
    # the asleep contract is "wakes on your next message", so WAKE it and
    # deliver (wake_and_enqueue). Only if that also fails does the hook keep
    # the text and a short flash explain — the error is the last resort, never
    # the first response.
    id = socket.assigns.selected_id

    result =
      case ChatAgent.enqueue_message(id, message) do
        :ok -> :ok
        {:error, :queue_full} = e -> e
        {:error, :unavailable} -> AgentLifecycle.wake_and_enqueue(id, message)
      end

    # ONE message channel: the reply's `note` renders inline under the
    # composer (the ChatForm hook). No flash — an error toast AND an inline
    # note competing to explain the same thing was noise.
    case result do
      :ok ->
        # Optimistic queue: enqueue_message already wrote the new pending list
        # to ETS synchronously, so pull it into THIS reply's diff. Otherwise the
        # queued card only appears when the StatusChanged broadcast is processed
        # — and while the agent is thinking, that broadcast waits behind a
        # backlog of streaming-token messages in the mailbox, so the box clears
        # but the card visibly lags. Rendering it here lands the card in the same
        # frame as the ack; the in-flight broadcast then overwrites with the
        # identical list (no flicker). If the agent was idle, ETS pending is
        # still [] (the message sent immediately) → nothing rendered here.
        socket = AgentEvents.refresh_selected_from_agents(socket, id, socket.assigns.agents)
        {:reply, %{ok: true}, socket}

      {:error, :queue_full} ->
        {:reply,
         %{
           ok: false,
           note: "The agent's queue is full — wait for it to catch up, then resend."
         }, socket}

      {:error, :unavailable} ->
        {:reply,
         %{ok: false, note: "⚠ Couldn't wake the agent — your text is kept; try Send again."},
         socket}
    end
  end
end
