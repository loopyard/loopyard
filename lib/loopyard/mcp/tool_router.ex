defmodule Loopyard.MCP.ToolRouter do
  @moduledoc """
  Pure dispatch layer behind the ACP MCP HTTP bridge.

  Turns an MCP `tools/list` / `tools/call` into the same `Loopyard.Tool`
  `execute/2` the in-process ClaudeCode backend calls — so the tool
  *implementations* (and their approval gates, workspace scoping, and
  `authorize_agent/2` binding) are shared verbatim across both transports. Only
  the wire differs.

  Two responsibilities:

    * **Param marshalling.** MCP delivers args as a string-keyed JSON map. Our
      tools pattern-match atom keys for their *declared* params but keep nested
      structures string-keyed (e.g. `ask_user`'s question objects). So we
      convert only the top-level keys named in the tool's `input_schema` to
      atoms and leave every value untouched — mirroring what the SDK's MCP
      backend hands the tools today.

    * **Identity binding.** The `agent_id` is taken from the verified bearer
      token, NEVER from the JSON the model sent. We force it into the params, so
      `authorize_agent/2` always sees a matching bound/supplied id and a model
      can't target another agent's workspace by passing a foreign id.

  No GenServer state, no PubSub — safe to unit-test directly.
  """

  alias Loopyard.ChatAgent.ToolConfig

  @doc """
  The MCP server name the ACP harness sees. Kept identical to the in-process
  toolkit name so the agent instructions (`mcp__loopyard-container__…`) resolve
  the same tool names on both backends.
  """
  def server_name, do: "loopyard-container"

  @doc """
  Tool modules exposed over the ACP MCP bridge for a token `scope`:

    * `:workspace` — the container/service control-plane subset (default).
    * `:operator` — the operator's project/identity control-plane toolkit.
  """
  def tool_modules(scope \\ :workspace)
  def tool_modules(:operator), do: ToolConfig.acp_operator_tools()
  def tool_modules(_workspace), do: ToolConfig.acp_control_plane_tools()

  @doc """
  MCP `tools/list` payload — one entry per exposed tool, bare-named.
  """
  def list_tools(modules \\ tool_modules()) do
    Enum.map(modules, fn mod ->
      %{
        "name" => mod.__tool_name__(),
        "description" => mod.__description__(),
        "inputSchema" => mod.input_schema()
      }
    end)
  end

  @doc """
  Run one `tools/call`. `agent_id` comes from the verified token and overrides
  any `agent_id` in `args`. Returns an MCP tool-result map
  (`%{"content" => [...], "isError" => bool}`), or `{:error, :unknown_tool}`
  when the name isn't in the exposed set.
  """
  def call_tool(name, args, agent_id, modules \\ tool_modules())
      when is_binary(name) and is_map(args) and is_binary(agent_id) do
    case Enum.find(modules, fn mod -> mod.__tool_name__() == name end) do
      nil ->
        {:error, :unknown_tool}

      mod ->
        params =
          mod
          |> atomize_params(args)
          # The token's identity wins — drop whatever the model supplied.
          |> Map.put(:agent_id, agent_id)

        mod.execute(params, %{agent_id: agent_id}) |> to_mcp_result()
    end
  end

  # Convert only the top-level keys the tool declares (schema property names),
  # leaving values — including nested maps/lists — as raw JSON. The property
  # names are compile-time atoms from the params DSL, so `to_existing_atom` is
  # safe and can't be used to exhaust the atom table.
  defp atomize_params(mod, args) do
    allowed = Map.keys(mod.input_schema()["properties"] || %{})

    for key <- allowed, Map.has_key?(args, key), into: %{} do
      {String.to_existing_atom(key), args[key]}
    end
  end

  # Map the tool's `{:ok, _} | {:error, _} | :ok | binary` contract onto MCP's
  # tool-result shape. Structured (non-binary) results are JSON-encoded into a
  # text block — the model reads text, and it keeps us off MCP structuredContent
  # (uneven adapter support).
  defp to_mcp_result({:ok, text}) when is_binary(text), do: ok_text(text)
  defp to_mcp_result({:ok, data}), do: ok_text(encode(data))
  defp to_mcp_result(:ok), do: ok_text("ok")
  defp to_mcp_result(text) when is_binary(text), do: ok_text(text)
  defp to_mcp_result({:error, msg}), do: error_text(err_text(msg))
  defp to_mcp_result(other), do: ok_text(encode(other))

  defp ok_text(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}

  defp error_text(text),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}

  defp encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> inspect(data)
    end
  end

  defp err_text(msg) when is_binary(msg), do: msg
  defp err_text(msg), do: inspect(msg)
end
