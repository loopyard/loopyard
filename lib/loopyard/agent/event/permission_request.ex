defmodule Loopyard.Agent.Event.PermissionRequest do
  @moduledoc """
  An agent is asking for permission to run a tool (ACP `session/request_permission`).

  Unlike other events, this one expects a *reply*: the backend is blocked
  until a decision is made. The UI renders it as an approve/deny card
  (Foundation C / #7 — answerable from any device). `request_id` is the
  ACP JSON-RPC id the backend must respond to; `options` are the choices
  the agent offered, each `%{id, name, kind}` where kind is one of
  `allow_once | allow_always | reject_once | reject_always`.
  """
  defstruct [:request_id, :session_id, :tool_call_id, :tool_name, :title, :input, options: []]

  @type option :: %{id: String.t(), name: String.t() | nil, kind: String.t() | nil}

  @type t :: %__MODULE__{
          request_id: term(),
          session_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          title: String.t() | nil,
          input: map() | nil,
          options: [option()]
        }
end
