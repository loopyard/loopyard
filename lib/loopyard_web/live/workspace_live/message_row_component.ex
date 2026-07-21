defmodule LoopyardWeb.Live.WorkspaceLive.MessageRowComponent do
  @moduledoc """
  Thin LiveComponent wrapper around `Messages.chat_msg/1` for transcript rows.

  Exists purely for DIFF SKIPPING: `:key`ed comprehensions cannot skip
  entries whose bodies are function components (inside a comprehension the
  component's change-tracking is unknown, so every row re-rendered and
  re-shipped its dynamics on every parent render — measured ~80KB per
  append for a ~180-row window, on every broadcast that touched the LV).
  LiveComponents diff by id + assigns equality: a row whose assigns are
  unchanged sends NOTHING and isn't even re-rendered server-side.

  All events (toggle_result, …) still target the parent LiveView — no
  phx-target anywhere, so `handle_event` stays in WorkspaceLive. Keep this
  module logic-free; rendering lives in `Messages`.
  """
  use Phoenix.LiveComponent

  def render(assigns), do: LoopyardWeb.Live.WorkspaceLive.Messages.chat_msg(assigns)
end
