defmodule BoomLooper.Events.ChatAgent.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to the `"chat_agents"` topic.

  Move #3 of plans/coordination-hardening.md. Every LV that subscribes to
  chat-agent events declares `@behaviour BoomLooper.Events.ChatAgent.Subscriber`
  and implements the callbacks it cares about. Callbacks it doesn't care
  about can return `{:noreply, socket}` unchanged. The compiler flags any
  callback missing an `@impl` annotation.

  The behaviour is intentionally per-event: one callback per struct. No
  macro-generated dispatcher — per the plan, each LV writes two-line
  `handle_info(%Struct{} = e, socket)` clauses that call the matching
  callback. Explicit > clever.

  Callbacks receive the event struct and the LV socket, and return the
  standard Phoenix.LiveView `handle_info/2` result.
  """

  alias BoomLooper.Events.ChatAgent

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_started(ChatAgent.Started.t(), socket) :: result
  @callback on_stopped(ChatAgent.Stopped.t(), socket) :: result
  @callback on_booting(ChatAgent.Booting.t(), socket) :: result
  @callback on_boot_status(ChatAgent.BootStatus.t(), socket) :: result
  @callback on_boot_failed(ChatAgent.BootFailed.t(), socket) :: result
  @callback on_removed(ChatAgent.Removed.t(), socket) :: result
  @callback on_renamed(ChatAgent.Renamed.t(), socket) :: result
  @callback on_resumed(ChatAgent.Resumed.t(), socket) :: result
  @callback on_status_changed(ChatAgent.StatusChanged.t(), socket) :: result
  @callback on_quarantined(ChatAgent.Quarantined.t(), socket) :: result
  @callback on_released(ChatAgent.Released.t(), socket) :: result

  # NO @optional_callbacks. Move #3's primary contract is "missing
  # callback = compile warning via @impl." Marking everything
  # optional defeats that contract — silent drops become possible
  # again. Subscribers that don't care about a specific event must
  # implement the callback as `def on_x(_e, socket), do: {:noreply, socket}`
  # — explicit opt-out, not silent drop. See audit MEDIUM #5.
end
