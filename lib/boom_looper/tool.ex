defmodule BoomLooper.Tool do
  @moduledoc """
  Lightweight macro for MCP tool modules.

  Generates `__tool_name__/0`, `__description__/0`, and `input_schema/0`
  from module attributes. The tool module only needs to define `execute/2`.

  ## Usage

      defmodule BoomLooper.Tools.Container.Exec do
        use BoomLooper.Tool,
          name: "exec",
          description: "Run a shell command inside the container.",
          params: [
            agent_id: :string,
            command: {:string, required: true},
            timeout: {:integer, description: "Max seconds (default: 120)"}
          ]

        def execute(%{agent_id: id, command: cmd} = params, _assigns) do
          # tool logic
        end
      end

  ## Params DSL

  Each entry in `params` is `{name, type_or_tuple}`:

  - `:string` — shorthand for `{:string, []}`
  - `{:string, required: true}` — required field
  - `{:string, description: "..."}` — with description
  - `{:string, required: true, description: "..."}` — both

  Types: `:string`, `:integer`, `:number`, `:boolean`, `:map`, `:list`
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    params = Keyword.get(opts, :params, [])
    busy_words = Keyword.get(opts, :busy_words, [])

    schema = build_schema(params)

    quote do
      @doc false
      def __tool_name__, do: unquote(name)

      @doc false
      def __description__, do: unquote(description)

      @doc false
      def input_schema, do: unquote(Macro.escape(schema))

      @doc "Words shown in the thinking indicator when this tool is active."
      def __busy_words__, do: unquote(busy_words)

      @before_compile BoomLooper.Tool
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    # Wrap the tool's execute/2 with the agent_id authorization check.
    # The user defines `def execute(params, assigns)` normally; we make
    # it overridable and inject an outer execute that verifies the
    # `params.agent_id` the model sent matches the `assigns.agent_id`
    # the runtime bound to this MCP session at spawn. Mismatch ⇒ reject.
    #
    # When `assigns` has no bound id (e.g. direct-call tests that pass
    # `%{}`), authorization is skipped. Production always sets it via
    # `ChatAgent.ToolConfig.build_mcp_servers/2`.
    quote do
      defoverridable execute: 2

      def execute(params, assigns) do
        case BoomLooper.Tool.authorize_agent(params, assigns) do
          :ok -> super(params, assigns)
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Authorize a tool call against the session-bound agent_id.

  Each ChatAgent spawns its own MCP server with `assigns = %{agent_id: id}`
  — the runtime identity of *this* agent's session. The JSON param
  `agent_id` is still accepted for schema compatibility but is only
  advisory: it must match the bound id, or the call is rejected.

  Returns `:ok` when:
    * assigns has no bound id (test harness direct-calling a tool)
    * params.agent_id matches assigns.agent_id
    * params.agent_id is absent (tools that don't need it)

  Returns `{:error, message}` when the caller passed someone else's id.
  """
  def authorize_agent(params, assigns) when is_map(params) and is_map(assigns) do
    bound = assigns[:agent_id] || assigns["agent_id"]
    supplied = params[:agent_id] || params["agent_id"]

    cond do
      is_nil(bound) ->
        :ok

      is_nil(supplied) ->
        :ok

      bound == supplied ->
        :ok

      true ->
        {:error,
         "agent_id mismatch: this tool call is bound to session " <>
           "#{inspect(bound)} but was asked to act as #{inspect(supplied)}. " <>
           "Agents may only operate on their own workspace. Use your own " <>
           "agent_id (shown in the system prompt) — you cannot target " <>
           "another agent's workspace by passing its id."}
    end
  end

  def authorize_agent(_, _), do: :ok

  defp build_schema(params) do
    {properties, required} =
      Enum.reduce(params, {%{}, []}, fn {name, spec}, {props, req} ->
        {type, opts} = normalize_spec(spec)
        name_str = Atom.to_string(name)

        prop = %{"type" => type_string(type)}

        prop =
          if desc = Keyword.get(opts, :description),
            do: Map.put(prop, "description", desc),
            else: prop

        props = Map.put(props, name_str, prop)
        req = if Keyword.get(opts, :required, false), do: [name_str | req], else: req

        {props, req}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Enum.reverse(required)
    }
  end

  defp normalize_spec(type) when is_atom(type), do: {type, []}
  defp normalize_spec({type, opts}) when is_atom(type) and is_list(opts), do: {type, opts}

  defp type_string(:string), do: "string"
  defp type_string(:integer), do: "integer"
  defp type_string(:number), do: "number"
  defp type_string(:boolean), do: "boolean"
  defp type_string(:map), do: "object"
  defp type_string(:list), do: "array"
end
