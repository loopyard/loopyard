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

    schema = build_schema(params)

    quote do
      @doc false
      def __tool_name__, do: unquote(name)

      @doc false
      def __description__, do: unquote(description)

      @doc false
      def input_schema, do: unquote(Macro.escape(schema))
    end
  end

  defp build_schema(params) do
    {properties, required} =
      Enum.reduce(params, {%{}, []}, fn {name, spec}, {props, req} ->
        {type, opts} = normalize_spec(spec)
        name_str = Atom.to_string(name)

        prop = %{"type" => type_string(type)}
        prop = if desc = Keyword.get(opts, :description), do: Map.put(prop, "description", desc), else: prop

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
