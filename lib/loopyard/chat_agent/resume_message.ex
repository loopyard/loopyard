defmodule Loopyard.ChatAgent.ResumeMessage do
  @moduledoc """
  Builds the compact "here's what was happening" message handed to a freshly
  respawned CLI after a crash/restart, so the new session continues instead of
  booting amnesic. Pure — extracted from `Loopyard.ChatAgent` to keep that
  module under its size cap.
  """

  @doc """
  A short resume summary from the agent's recent messages, or `nil` when there's
  too little history (< 3 of the last 20 messages) to bother.
  """
  @spec build([map()]) :: String.t() | nil
  def build(messages) when is_list(messages) do
    recent = messages |> Enum.take(20) |> Enum.reverse()

    if length(recent) < 3 do
      nil
    else
      tool_names =
        recent
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.map(& &1[:tool])
        |> Enum.uniq()

      last_assistant = recent |> Enum.filter(&(&1.role == :assistant)) |> List.last()
      last_system = recent |> Enum.filter(&(&1.role in [:system, :build_done])) |> List.last()

      ["Your session crashed and was restarted. Here's what was happening:"]
      |> append_if(tool_names != [], "Recent tools used: #{Enum.join(tool_names, ", ")}")
      |> append_if(last_assistant, fn -> "Your last message: #{slice(last_assistant)}" end)
      |> append_if(last_system, fn -> "Last system status: #{slice(last_system)}" end)
      |> Kernel.++([
        "Continue where you left off. If you were setting up the dev environment, check service_status and follow the verification loop."
      ])
      |> Enum.join("\n\n")
    end
  end

  defp append_if(parts, cond, value)
  defp append_if(parts, falsy, _) when falsy in [nil, false], do: parts
  defp append_if(parts, _truthy, value) when is_function(value, 0), do: parts ++ [value.()]
  defp append_if(parts, _truthy, value), do: parts ++ [value]

  defp slice(msg), do: String.slice(msg.content, 0..500)
end
