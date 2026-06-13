defmodule Loopyard.Tools.Workstation.ReadDockerfile do
  use Loopyard.Tool,
    name: "read_dockerfile",
    description:
      "Read the workstation Dockerfile — the base image every agent (and your own console) is stamped from. Read it before editing so you preserve what's there.",
    busy_words: ["reading the Dockerfile"],
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Workstation.Image

  def execute(%{agent_id: _id}, _assigns) do
    case Image.read_dockerfile() do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Couldn't read the Dockerfile: #{inspect(reason)}"}
    end
  end
end
