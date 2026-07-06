defmodule Loopyard.Tool do
  @moduledoc """
  Lightweight macro for MCP tool modules.

  Generates `__tool_name__/0`, `__description__/0`, and `input_schema/0`
  from module attributes. The tool module only needs to define `execute/2`.

  ## Usage

      defmodule Loopyard.Tools.Container.Exec do
        use Loopyard.Tool,
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

      @before_compile Loopyard.Tool
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

      def execute(params, frame_or_assigns) do
        {assigns, frame} = Loopyard.Tool.__unwrap_frame__(frame_or_assigns)

        result =
          case Loopyard.Tool.authorize_agent(params, assigns) do
            :ok -> super(params, assigns)
            {:error, _} = err -> err
          end

        Loopyard.Tool.__reply__(result, frame)
      end
    end
  end

  # --- claude_code 0.36+ MCP contract adapter ------------------------------
  #
  # The SDK's Anubis backend now calls `execute(params, %Anubis.Server.Frame{})`
  # and expects `{:reply, %Anubis.Server.Response{}, frame}` back. Our tools (and
  # the direct-call tests) speak the simpler `{:ok, result}` / `{:error, msg}`.
  # These two helpers bridge the contracts in ONE place: when a Frame is present
  # (the SDK), translate to the Response shape; when it's a plain assigns map
  # (tests / direct calls), pass the raw result straight through. This keeps the
  # whole tool layer insulated from the SDK's MCP backend churn.

  @doc false
  def __unwrap_frame__(%Anubis.Server.Frame{assigns: assigns} = frame), do: {assigns, frame}
  def __unwrap_frame__(assigns) when is_map(assigns), do: {assigns, nil}

  @doc false
  # No frame ⇒ direct/test call: keep the {:ok, ...}/{:error, ...} contract.
  def __reply__(result, nil), do: result
  # Frame present ⇒ SDK call: adapt to {:reply, %Response{}, frame}.
  def __reply__({:ok, result}, frame), do: {:reply, __to_response__(result), frame}
  def __reply__(:ok, frame), do: {:reply, __to_response__("ok"), frame}

  def __reply__({:error, msg}, frame),
    do:
      {:reply, Anubis.Server.Response.error(Anubis.Server.Response.tool(), __err_text__(msg)),
       frame}

  def __reply__(other, frame), do: {:reply, __to_response__(other), frame}

  defp __to_response__(text) when is_binary(text),
    do: Anubis.Server.Response.text(Anubis.Server.Response.tool(), text)

  defp __to_response__(data),
    do: Anubis.Server.Response.json(Anubis.Server.Response.tool(), data)

  defp __err_text__(msg) when is_binary(msg), do: msg
  defp __err_text__(msg), do: inspect(msg)

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
