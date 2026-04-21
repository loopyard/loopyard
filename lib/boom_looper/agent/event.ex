defmodule BoomLooper.Agent.Event do
  @moduledoc """
  BoomLooper-native event types that decouple agent logic from any
  specific backend's message format. The UI and ChatAgent pattern-match
  on these structs.

  Each event is defined in its own file under `lib/boom_looper/agent/event/`
  (one module per file, Elixir-idiomatic). This module re-declares the
  union type for consumers that want to spec on `BoomLooper.Agent.Event.t()`.

  Keeping them in their own files — rather than nested `defmodule Y do
  defstruct([])` blocks inside a parent `BoomLooper.Agent.Event do ...` —
  is what makes the Elixir 1.19 parallel compiler reliably resolve
  `%Event.X{}` references in tests. Nested struct modules compile as a
  side effect of their parent's body, so a test file referencing the
  child could race with the parent's body.
  """

  alias BoomLooper.Agent.Event.{
    TextDelta,
    Text,
    ToolCall,
    ToolResult,
    SessionResult,
    RateLimitStatus,
    AuthStatus
  }

  @type t ::
          TextDelta.t()
          | Text.t()
          | ToolCall.t()
          | ToolResult.t()
          | SessionResult.t()
          | RateLimitStatus.t()
          | AuthStatus.t()
end
