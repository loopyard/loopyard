defmodule Loopyard.Tools.Workstation.RebuildImage do
  use Loopyard.Tool,
    name: "rebuild_image",
    description:
      "Rebuild the workstation image from the current Dockerfile. Output streams live to the build pane on the page; you get back the result + the tail of the log. Blocks until the build finishes (can take a few minutes on a cold build). Call this after write_dockerfile to apply changes — every agent is re-stamped from the result.",
    busy_words: ["rebuilding the image", "running docker build"],
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Events
  alias Loopyard.Events.Workstation.{BuildDone, BuildOutput}
  alias Loopyard.Workstation.Image

  # How much of the build log to hand back to the agent (the full log streams to
  # the human via the build pane). Keep the model's context lean.
  @tail_bytes 6_000

  def execute(%{agent_id: _id}, _assigns) do
    {:ok, agent} = Agent.start_link(fn -> "" end)

    result =
      Image.build(fn data ->
        Agent.update(agent, &(&1 <> data))
        Events.Workstation.publish(%BuildOutput{data: data})
      end)

    log = Agent.get(agent, & &1)
    Agent.stop(agent)

    Events.Workstation.publish(%BuildDone{result: result})

    case result do
      :ok ->
        status = Image.status()
        size = if status.exists, do: status.size, else: "unknown size"
        {:ok, "✓ Build succeeded. Image is #{size}. Every agent now stamps from it."}

      {:error, reason} ->
        {:error, "✗ Build failed (#{inspect(reason)}).\n\nLast output:\n#{tail(log)}"}
    end
  end

  defp tail(log) when byte_size(log) > @tail_bytes,
    do: binary_part(log, byte_size(log) - @tail_bytes, @tail_bytes)

  defp tail(log), do: log
end
