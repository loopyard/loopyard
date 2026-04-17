defmodule BoomLooper.Agents.Agent do
  @moduledoc """
  A loaded agent definition. Built from an `agent.md` file on disk.

  The `folder` field is the absolute path to the agent's directory —
  used by `read_agent_file` to sandbox file access to files inside
  that folder.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          model: String.t(),
          tools: [String.t()],
          disallowed_tools: [String.t()],
          gates: map(),
          body: String.t(),
          folder: String.t()
        }

  defstruct [
    :name,
    :description,
    :folder,
    :body,
    model: "sonnet",
    tools: [],
    disallowed_tools: [],
    gates: %{}
  ]
end
