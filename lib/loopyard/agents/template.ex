defmodule Loopyard.Agents.Template do
  @moduledoc """
  The STAMP an agent is made from. An agent is four things brought together:

    1. **compute** — the container its tools act in (`:workspace` = the code
       volume's work container; `:workstation` = the identity's workstation
       container).
    2. **tools** — the MCP scope it gets (`:workspace` = the container
       toolkit, bound to one workspace; `:system` = the control-plane toolkit,
       aware of every agent and workspace).
    3. **loop + model** — what drives model + tools (`:acp` = a coding harness
       in the container; `:direct` = a model API loop in the BEAM), and which
       model.
    4. **context** — the brief: shared doctrine blocks (`priv/agents/_shared/`)
       + the template's own body (`priv/agents/<id>/agent.md`) + the support
       files it can read on demand + runtime facts the prompt builder adds.

  Today the templates are CODE — `coding/0` and `system/0` are presets with
  fixed values for the two compositions Loopyard runs. When the UI grows a way
  to configure them, the presets become data; nothing above this module needs
  to change for that. The prompt BODIES already live on disk as `agent.md`.
  """

  alias Loopyard.Agents.Loader

  @type compute :: :workspace | :workstation
  @type tools :: :workspace | :system
  @type loop :: :acp | :direct

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          folder: String.t(),
          body: String.t(),
          compute: compute(),
          tools: tools(),
          loop: loop(),
          model: String.t() | nil,
          context: [String.t()]
        }

  defstruct [
    :id,
    :name,
    :description,
    :folder,
    :body,
    compute: :workspace,
    tools: :workspace,
    loop: :acp,
    model: nil,
    context: []
  ]

  @ids ~w(coding system)

  @doc """
  The workspace agent: works on one project's code in its work container,
  with the container toolkit. Bootstraps the dev environment only if it's
  missing.
  """
  @spec coding() :: t()
  def coding do
    stamp("coding",
      compute: :workspace,
      tools: :workspace,
      context: ["workspace-tools", "decisions"]
    )
  end

  @doc """
  The system agent: the user's chief of staff, in the workstation container,
  with the control-plane toolkit — aware of every workspace and agent, hands
  work out, keeps the human in the loop. The operator is the first of these.
  """
  @spec system() :: t()
  def system do
    stamp("system", compute: :workstation, tools: :system, context: ["decisions", "phone-screen"])
  end

  @doc "Every template Loopyard can stamp."
  @spec all() :: [t()]
  def all, do: Enum.map(@ids, &fetch!/1)

  @doc "Is `id` a template id?"
  @spec exists?(term()) :: boolean()
  def exists?(id), do: is_binary(id) and id in @ids

  @doc "Fetch a template by id."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, :unknown_template}
  def fetch("coding"), do: {:ok, coding()}
  def fetch("system"), do: {:ok, system()}
  def fetch(_), do: {:error, :unknown_template}

  @doc "Fetch a template by id, raising on an unknown id."
  @spec fetch!(String.t()) :: t()
  def fetch!(id) do
    case fetch(id) do
      {:ok, t} -> t
      {:error, _} -> raise ArgumentError, "unknown agent template #{inspect(id)}"
    end
  end

  @doc "On-disk folder holding a template's `agent.md` + support files."
  @spec folder(String.t()) :: String.t()
  def folder(id) when is_binary(id), do: Application.app_dir(:loopyard, "priv/agents/#{id}")

  @doc "The shared-blocks folder."
  def shared_folder, do: Application.app_dir(:loopyard, "priv/agents/_shared")

  @doc """
  Support files the agent can `read_agent_file` on demand — relative paths,
  sorted. Excludes `agent.md`/`Dockerfile` (Loopyard's own metadata, not
  content for the agent to read).
  """
  @spec catalog(t()) :: [String.t()]
  def catalog(%__MODULE__{folder: folder}) do
    Path.wildcard(Path.join([folder, "**", "*"]))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&(Path.relative_to(&1, folder) |> to_string()))
    |> Enum.reject(&(&1 in ["agent.md", "Dockerfile"]))
    |> Enum.sort()
  end

  @doc "The shared doctrine blocks, in the template's order."
  @spec blocks(t()) :: [String.t()]
  def blocks(%__MODULE__{context: ids}) do
    Enum.map(ids, fn id ->
      shared_folder() |> Path.join(id <> ".md") |> File.read!() |> String.trim()
    end)
  end

  @doc "The supervision + persistence scope: a workspace's, or the system's."
  @spec scope(t()) :: :workspace | :system
  def scope(%__MODULE__{compute: :workspace}), do: :workspace
  def scope(%__MODULE__{}), do: :system

  @doc "The MCP bridge scope the template's tools are served under."
  @spec mcp_scope(t()) :: :workspace | :system
  def mcp_scope(%__MODULE__{tools: tools}), do: tools

  @doc "Is this a system (workspace-less) template?"
  @spec system?(t()) :: boolean()
  def system?(%__MODULE__{} = t), do: scope(t) == :system

  # Load the on-disk body for `id` and stamp the preset composition onto it.
  defp stamp(id, preset) do
    folder = folder(id)

    case Loader.load(folder) do
      {:ok, %{name: name, description: description, body: body, model: model}} ->
        struct!(
          __MODULE__,
          [id: id, name: name, description: description, folder: folder, body: body, model: model] ++
            preset
        )

      {:error, reason} ->
        raise "agent template #{id} failed to load from #{folder}: #{inspect(reason)}"
    end
  end
end
