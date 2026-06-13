defmodule Loopyard.Tools.Workstation.WriteDockerfile do
  use Loopyard.Tool,
    name: "write_dockerfile",
    description:
      "Replace the workstation Dockerfile with new contents (full file, not a patch). This does NOT rebuild — call rebuild_image after to apply it. Tools/system packages belong here (baked into the image); logins and dotfiles live in $HOME and must NOT be put in the Dockerfile. Keep it a valid Debian bookworm build; install tools to system paths (/usr/local), never $HOME (the $HOME volume would shadow them).",
    busy_words: ["editing the Dockerfile"],
    params: [
      agent_id: {:string, required: true},
      contents: {:string, required: true, description: "The complete new Dockerfile contents."}
    ]

  alias Loopyard.Workstation.Image

  def execute(%{agent_id: _id, contents: contents}, _assigns) when is_binary(contents) do
    case Image.write_dockerfile(contents) do
      :ok ->
        {:ok, "Dockerfile updated (#{byte_size(contents)} bytes). Call rebuild_image to apply it."}

      {:error, reason} ->
        {:error, "Couldn't write the Dockerfile: #{inspect(reason)}"}
    end
  end
end
