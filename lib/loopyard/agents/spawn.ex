defmodule Loopyard.Agents.Spawn do
  @moduledoc """
  THE spawn path. Every agent — a workspace's or a system one — is stamped
  from a `Loopyard.Agents.Template` here, registered as booting (so it lands
  in ETS at once), and booted by the `Loopyard.AgentBoot` saga, whose steps
  follow the template's scope: a workspace agent gets its work container
  ensured; a system agent gets its identity's workstation container ensured
  and lands under the identity's `SystemGroup`.

  The operator used to have its own path (a synchronous bang-match under a
  bare DynamicSupervisor, no booting stub, no saga); that path is gone.
  """

  alias Loopyard.{AgentBoot, ChatAgent, WorkspaceRegistry, Workstation}
  alias Loopyard.Agents.Template

  # Boot opts that ride straight through to the Initializer (the rebuildable
  # set plus the history seed for a respawn with a stable id).
  @forwarded ~w(template_id backend harness model tools host_access initial_messages claude_session_id pending_sends)a

  @doc """
  Spawn an agent from `template_id`.

  Options: `:workspace_id` (required for a workspace template),
  `:workstation_identity` (system template; default the current identity),
  `:id` (respawn with a STABLE id), `:name`, `:service_name`,
  `:initial_message` (`:none` to skip), `:started_by`, plus the forwarded
  boot opts (`:backend`, `:harness`, `:model`, `:initial_messages`,
  `:claude_session_id`, `:pending_sends`).

  Returns `{:ok, agent_id}` or `{:error, reason}`.
  """
  @spec spawn(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def spawn(template_id, opts \\ []) do
    with {:ok, template} <- Template.fetch(template_id) do
      case Template.scope(template) do
        :workspace -> spawn_workspace(template, opts)
        :system -> spawn_system(template, opts)
      end
    end
  end

  defp spawn_workspace(template, opts) do
    ws_id = Keyword.get(opts, :workspace_id)

    case ws_id && WorkspaceRegistry.get_workspace(ws_id) do
      nil ->
        {:error, :not_found}

      ws ->
        working_dir = ws[:path] || ws[:working_dir]
        service_name = Keyword.get(opts, :service_name)

        name =
          Keyword.get(opts, :name) ||
            cond do
              service_name -> "#{service_name}-agent"
              true -> Loopyard.Agents.Name.for_workspace(ws_id, Keyword.get(opts, :backend))
            end

        id = Keyword.get(opts, :id) || new_id()

        agent_opts =
          [
            id: id,
            name: name,
            working_dir: working_dir,
            started_by: Keyword.get(opts, :started_by, "system"),
            workspace_id: ws_id,
            template_id: template.id,
            scope: :workspace,
            # Inherit THIS workspace's workstation identity (its creds/home), not
            # the global `current` — so agents in a workspace attached to another
            # workstation follow that identity.
            workstation_identity: Loopyard.Workspace.workstation_id(ws)
          ]
          |> maybe(:service_name, service_name)
          |> forward(opts)

        # SECURITY BOUNDARY — workspace agents are ALWAYS container-only. No
        # `bind_mount` here, ever (docs/SECURITY.md).
        boot_opts =
          cond do
            service_name -> [service_name: service_name]
            msg = Keyword.get(opts, :initial_message) -> [initial_message: msg]
            true -> [initial_message: :none]
          end

        register_opts =
          [workspace_id: ws_id, template_id: template.id, scope: :workspace]
          |> maybe(:service_name, service_name)

        ChatAgent.register_booting(id, name, working_dir, register_opts)
        AgentBoot.start_monitored(id, agent_opts, boot_opts)
        {:ok, id}
    end
  end

  defp spawn_system(template, opts) do
    identity = Keyword.get(opts, :workstation_identity) || Workstation.current()
    id = Keyword.get(opts, :id) || new_id()
    # A scratch cwd; the real work is the control-plane tools + the container.
    working_dir = Path.join([Workstation.dir(identity), "agents"])
    File.mkdir_p!(working_dir)

    name =
      Keyword.get(opts, :name) ||
        Loopyard.Agents.Name.dedupe(
          template.name,
          Enum.map(Loopyard.Agents.system(identity), & &1.name)
        )

    agent_opts =
      [
        id: id,
        name: name,
        working_dir: working_dir,
        bind_mount: nil,
        workspace_id: nil,
        started_by: Keyword.get(opts, :started_by, "system"),
        template_id: template.id,
        scope: :system,
        workstation_identity: identity
      ]
      |> forward(opts)

    boot_opts = [initial_message: Keyword.get(opts, :initial_message, :none)]

    ChatAgent.register_booting(id, name, working_dir,
      workstation_identity: identity,
      template_id: template.id,
      scope: :system
    )

    AgentBoot.start_monitored(id, agent_opts, boot_opts)
    {:ok, id}
  end

  defp forward(agent_opts, opts) do
    Enum.reduce(@forwarded, agent_opts, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        val -> Keyword.put(acc, key, val)
      end
    end)
  end

  defp maybe(kw, _key, nil), do: kw
  defp maybe(kw, key, val), do: Keyword.put(kw, key, val)

  defp new_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
