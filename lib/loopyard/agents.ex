defmodule Loopyard.Agents do
  @moduledoc """
  Every agent Loopyard runs, whatever its scope — and the registry of the
  SYSTEM ones. An agent is stamped from a `Loopyard.Agents.Template`; its
  SCOPE is where it lives:

    * `:workspace` — bound to one project workspace (the work container on the
      code volume, the workspace's agent log, the workspace's supervision group).
    * `:system` — workspace-less, bound to a workstation identity (the
      workstation container, the identity's `agents.log`, the identity's
      `SystemGroup`). The operator is the first of these; there can be many.

  `scope/1` is the ONE place that derivation lives. Every other reader asks
  the summary's `:scope` field and falls back here for rows written before
  the field existed.

  **System agents persist like workspace agents.** The identity's
  `<workstation dir>/agents.log` (one writer: the group's Checkpointer)
  holds every system agent's `{:agent, …}` record + transcript; `restore/1`
  replays it into ETS at boot, exactly as `restore_all_agents` does per
  workspace. The marker `<workstation dir>/agents.json` names the DEFAULT
  system agent (the one `/operator` opens). `migrate!/1` carries the old
  operator's `operator.json` + `operator-agent.log` across, keeping its id
  and history.
  """

  alias Loopyard.{AgentLog, ChatAgent, Onboarding, Workstation}
  alias Loopyard.ChatAgent.Persistence

  @type scope :: :workspace | :system

  # ── scope ────────────────────────────────────────────────────────────────

  @doc "The scope of an agent summary/state map."
  @spec scope(map()) :: scope()
  def scope(%{scope: scope}) when scope in [:workspace, :system], do: scope
  def scope(%{workspace_id: ws}) when is_binary(ws), do: :workspace
  def scope(_), do: :system

  @doc """
  The key its supervision + persistence hang off: a workspace id, or
  `{:system, workstation_identity}`.
  """
  @spec scope_key(map()) :: String.t() | {:system, String.t()}
  def scope_key(%{workspace_id: ws} = summary) when is_binary(ws) do
    if scope(summary) == :workspace, do: ws, else: {:system, identity(summary)}
  end

  def scope_key(summary), do: {:system, identity(summary)}

  # ── reads (ETS only — safe on a mount path) ──────────────────────────────

  @doc "Every agent, system ones first, then newest first — THE flat read."
  @spec summaries() :: [map()]
  def summaries do
    ChatAgent.list_agent_summaries()
    |> Enum.sort_by(fn s -> {scope_rank(scope(s)), -started_unix(s)} end)
  rescue
    _ -> []
  end

  @doc "The system agents of one identity."
  @spec system(String.t()) :: [map()]
  def system(identity \\ Workstation.current()) do
    summaries()
    |> Enum.filter(&(scope(&1) == :system and identity(&1) == identity))
  end

  @doc "One agent's summary by id, or nil."
  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    case :ets.lookup(:chat_agents, id) do
      [{^id, summary}] -> summary
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def get(_), do: nil

  @doc "The identity's DEFAULT system agent id (the operator), if it exists in ETS."
  @spec default_id(String.t()) :: String.t() | nil
  def default_id(identity \\ Workstation.current()) do
    migrate!(identity)

    case marker(identity)["default_agent_id"] do
      id when is_binary(id) -> if get(id), do: id, else: nil
      _ -> nil
    end
  end

  @doc "Is the agent's GenServer alive (not merely present in ETS)?"
  @spec alive?(String.t()) :: boolean()
  def alive?(id) when is_binary(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  rescue
    _ -> false
  end

  def alive?(_), do: false

  # ── lifecycle ────────────────────────────────────────────────────────────

  @doc """
  Ensure the identity's default system agent exists and is running: alive →
  nothing; known but dead → resume it (its transcript replays from the log);
  none → stamp a fresh "Operator" from the system template and remember it.
  Serialised per identity. Returns `{:ok, %{agent_id: id}}`.
  """
  @spec ensure_default(String.t()) :: {:ok, %{agent_id: String.t()}} | {:error, term()}
  def ensure_default(identity \\ Workstation.current()) do
    :global.trans({{__MODULE__, :default, identity}, self()}, fn ->
      case default_id(identity) do
        id when is_binary(id) ->
          with :ok <- ensure_running(id), do: {:ok, %{agent_id: id}}

        nil ->
          with {:ok, id} <- create_system(name: "Operator", workstation_identity: identity) do
            save_marker(identity, %{"default_agent_id" => id})
            {:ok, %{agent_id: id}}
          end
      end
    end)
  end

  @doc """
  Make sure an agent known to ETS has a live process: a dead system agent's
  container is ensured and it resumes under its SystemGroup; a workspace one
  resumes under its group. `{:error, :not_found}` for an unknown id.
  """
  @spec ensure_running(String.t()) :: :ok | {:error, term()}
  def ensure_running(id) do
    cond do
      alive?(id) ->
        :ok

      summary = get(id) ->
        with :ok <- ensure_compute(summary),
             result <- ChatAgent.Lifecycle.start_agent(id) do
          case result do
            :ok -> :ok
            {:error, "Agent already running"} -> :ok
            other -> other
          end
        end

      true ->
        {:error, :not_found}
    end
  end

  defp ensure_compute(summary) do
    if scope(summary) == :system do
      case container_mod().ensure_up(identity(summary)) do
        {:ok, _} -> :ok
        other -> {:error, {:workstation_container, other}}
      end
    else
      :ok
    end
  end

  @doc """
  Stamp a NEW system agent for an identity. Options: `:name` (default the
  template's, deduped), `:template_id` (default `"system"`),
  `:workstation_identity`, `:initial_message`. Boots via the saga; returns
  `{:ok, agent_id}` at once (the agent shows as booting).
  """
  @spec create_system(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_system(opts \\ []) do
    template_id = Keyword.get(opts, :template_id, "system")
    identity = Keyword.get(opts, :workstation_identity) || Workstation.current()
    _ = Loopyard.Agents.SystemSupervisor.ensure_group(identity)

    Onboarding.spawn_agent(
      template_id,
      Keyword.merge(opts, workstation_identity: identity, started_by: "system")
    )
  end

  @doc "Where an agent's chat attachments live (see `Loopyard.Attachments`)."
  @spec attachment_target(String.t() | nil) :: Loopyard.Attachments.target() | nil
  def attachment_target(id) do
    case get(id) do
      %{workspace_id: ws} = s when is_binary(ws) ->
        if scope(s) == :workspace, do: {:workspace, ws}, else: system_target(s)

      %{} = s ->
        system_target(s)

      nil ->
        nil
    end
  end

  @doc "The attachment target of the current identity's workstation (before any agent exists)."
  @spec default_attachment_target(String.t()) :: Loopyard.Attachments.target()
  def default_attachment_target(identity \\ Workstation.current()),
    do: {:container, Workstation.container_name(identity), "/home/#{identity}"}

  defp system_target(summary) do
    identity = identity(summary)
    {:container, summary[:container] || Workstation.container_name(identity), "/home/#{identity}"}
  end

  # ── persistence: migration + boot restore ────────────────────────────────

  @doc "The identity's system agents log."
  def log_path(identity), do: Persistence.system_log_path(identity)

  @doc """
  Replay the identity's system agents into ETS (asleep; the page or
  `ensure_running/1` wakes them), the way `restore_all_agents` does per
  workspace. Rows from before scopes existed are patched with their scope
  and template so every reader sees the stamp. Returns the count restored.
  """
  @spec restore(String.t()) :: non_neg_integer()
  def restore(identity) do
    migrate!(identity)
    path = log_path(identity)

    if File.exists?(path) do
      case AgentLog.replay(log_path: path, version: 1, ets_table: :chat_agents) do
        {:ok, agents} when map_size(agents) > 0 ->
          restorable = AgentLog.restorable(agents)
          Enum.each(Map.keys(restorable), &patch_legacy_row(&1, identity))
          map_size(restorable)

        _ ->
          0
      end
    else
      0
    end
  rescue
    e ->
      Loopyard.EventLog.error("agents", "restore #{identity} failed: #{Exception.message(e)}")
      0
  end

  @doc """
  Carry the pre-registry operator across, once and idempotently:
  `operator.json` → `agents.json` (the default id), `operator-agent.log` →
  `agents.log` (same ETF format — id, transcript, native session id and
  queued messages survive untouched).
  """
  @spec migrate!(String.t()) :: :ok
  def migrate!(identity) do
    dir = Workstation.dir(identity)
    old_marker = Path.join(dir, "operator.json")
    old_log = Persistence.operator_log_path(identity)

    if File.exists?(old_marker) and not File.exists?(marker_path(identity)) do
      case Jason.decode(File.read!(old_marker)) do
        {:ok, %{"agent_id" => id}} when is_binary(id) ->
          save_marker(identity, %{"default_agent_id" => id})

        _ ->
          :ok
      end
    end

    if File.exists?(old_log) and not File.exists?(log_path(identity)) do
      File.rename!(old_log, log_path(identity))
    end

    :ok
  rescue
    e ->
      Loopyard.EventLog.error(
        "agents",
        "migration for #{identity} failed: #{Exception.message(e)}"
      )

      :ok
  end

  @doc false
  def marker_path(identity), do: Path.join(Workstation.dir(identity), "agents.json")

  # ── internals ────────────────────────────────────────────────────────────

  defp patch_legacy_row(id, identity) do
    case :ets.lookup(:chat_agents, id) do
      [{^id, row}] ->
        patched =
          row
          |> Map.update(:scope, :system, &(&1 || :system))
          |> Map.update(:template_id, "system", &(&1 || "system"))
          |> Map.update(:workstation_identity, identity, &(&1 || identity))

        :ets.insert(:chat_agents, {id, patched})

      _ ->
        :ok
    end
  end

  defp marker(identity) do
    case File.read(marker_path(identity)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_marker(identity, map) do
    path = marker_path(identity)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map))
  end

  defp identity(%{workstation_identity: id}) when is_binary(id), do: id
  defp identity(_), do: Workstation.current()

  defp container_mod,
    do: Application.get_env(:loopyard, :workstation_container, Loopyard.Workstation.Container)

  defp scope_rank(:system), do: 0
  defp scope_rank(_), do: 1

  defp started_unix(%{started_at: %DateTime{} = t}), do: DateTime.to_unix(t)
  defp started_unix(_), do: 0
end
