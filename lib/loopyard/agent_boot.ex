defmodule Loopyard.AgentBoot do
  @moduledoc """
  Shared agent boot logic used by both the LiveView and the System API.
  Handles service startup and sending the initial message.

  ## Saga structure (Move #7a)

  The boot flow runs as a `Loopyard.Saga` so each step's failure
  triggers explicit rollback of prior steps. Steps:

    1. `:load_config` — read workspace config from the volume. Pure
       read; no rollback.
    2. `:ensure_services` — make the workspace *workable*. For
       volume-backed workspaces this brings up the cheap, code-mounted
       `WorkContainer` (north-star D10: "working is the default" — an
       agent does NOT boot the dev/preview cluster just to start; the
       agent or a human boots preview on demand). Legacy host
       bind-mount projects keep the old behavior (compose-up via
       `ServiceManager.start_services`). For Setup agents, failure is a
       soft error (they exist to fix broken infrastructure). Rollback:
       no-op — a container staying up on failure is fine; the next boot
       reuses it.
    3. `:start_agent` — spawn the ChatAgent GenServer under the
       workspace supervisor (with one rebuild-retry). Rollback:
       `ChatAgent.stop_agent/1` — terminates the GenServer so we don't
       leak it when step 4 fails.
    4. `:send_initial_message` — cast the first user message. Only
       fires if `initial_message` isn't `:none` and a default message
       exists.

  On failure, `boot_failed/2` is called outside the saga so the UI
  sees the transient `:chat_agent_boot_failed` event and clears the
  `:booting` ETS entry regardless of which saga step tripped.
  """
  require Logger

  alias Loopyard.{ChatAgent, Saga, Workspace}

  @doc """
  Fire-and-forget boot under a supervised Task, plus a monitor Task that
  surfaces boot-process death to the user within ~100ms instead of the
  5-min `@stuck_booting_seconds` UI backstop.

  Motivation — agent-sanity #9. Callers currently do:

      Task.Supervisor.start_child(TaskSupervisor, fn -> AgentBoot.boot(...) end)

  `boot/3` handles saga errors via `ChatAgent.boot_failed/2`, but if
  the Task PROCESS itself dies (OS kill, TaskSupervisor :shutdown
  timeout, a raise in a tools/2 callback that no rescue catches), the
  `boot_failed` path never runs and the user stares at a "Booting..."
  spinner for 5 minutes before the stuck-booting heuristic kicks in.

  `start_monitored/3` spawns the boot Task as `async_nolink` (so the
  caller isn't linked) and spawns a sibling watcher Task under the
  same supervisor that calls `Process.monitor/1` on the boot pid. On
  `:DOWN` with a non-`:normal` reason, the watcher checks whether the
  agent is still in `:booting` status and, if so, calls
  `boot_failed/2` — surfacing the crash reason inline in the UI
  immediately.

  The watcher also carries a hard deadline (2 min, overridable via
  `:boot_deadline_ms` opt) — if the boot hasn't finished by then,
  the watcher force-fails the agent with `:boot_deadline_exceeded`
  so we catch wedged boots that didn't actually crash but are stuck
  (e.g. a docker compose up hanging on a network stall).
  """
  def start_monitored(id, agent_opts, opts \\ []) do
    deadline_ms = Keyword.get(opts, :boot_deadline_ms, 120_000)

    boot_task =
      Task.Supervisor.async_nolink(Loopyard.TaskSupervisor, fn ->
        boot(id, agent_opts, opts)
      end)

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      ref = Process.monitor(boot_task.pid)

      receive do
        {:DOWN, ^ref, :process, _, :normal} ->
          # Boot returned (cleanly or via boot_failed) — nothing to do.
          :ok

        {:DOWN, ^ref, :process, _, reason} ->
          case :ets.lookup(:chat_agents, id) do
            [{^id, %{status: :booting}}] ->
              Logger.warning(
                "[AgentBoot.Monitor] #{id} boot task crashed without running " <>
                  "boot_failed: #{inspect(reason)}. Surfacing to UI."
              )

              ChatAgent.boot_failed(id, {:boot_task_crashed, reason})

            _ ->
              :ok
          end
      after
        deadline_ms ->
          # Boot wedged past deadline. Kill the boot task + fail.
          Process.demonitor(ref, [:flush])

          case :ets.lookup(:chat_agents, id) do
            [{^id, %{status: :booting}}] ->
              Logger.warning(
                "[AgentBoot.Monitor] #{id} boot exceeded deadline #{deadline_ms}ms, force-failing."
              )

              Process.exit(boot_task.pid, :kill)
              ChatAgent.boot_failed(id, :boot_deadline_exceeded)

            _ ->
              :ok
          end
      end
    end)

    :ok
  end

  @doc """
  Boot an agent: start services, start the Claude session, and send the initial message.
  Call from a Task — this blocks until the session starts.

  Options:
    - :service_name — service to debug
    - :initial_message — override the default first message
  """
  def boot(id, agent_opts, opts \\ []) do
    working_dir = Keyword.fetch!(agent_opts, :working_dir)
    service_name = Keyword.get(opts, :service_name)
    initial_message = Keyword.get(opts, :initial_message)
    scope = Keyword.get(agent_opts, :scope) || :workspace

    # A SYSTEM agent has no workspace: its compute is the identity's
    # workstation container, its group the identity's SystemGroup.
    {workspace_id, key, steps} =
      case scope do
        :system ->
          identity =
            Keyword.get(agent_opts, :workstation_identity) || Loopyard.Workstation.current()

          key = {:system, identity}

          {nil, key,
           [
             ensure_workstation_step(id, identity),
             start_agent_step(id, key, agent_opts, working_dir),
             send_initial_message_step(id, initial_message, service_name)
           ]}

        _ ->
          # Use workspace_id from opts if provided (volume-based workspaces pass it),
          # otherwise compute from path (bind-mount workspaces)
          workspace_id =
            Keyword.get(agent_opts, :workspace_id) || Workspace.workspace_id(working_dir)

          # Volume-based workspaces pass the volume name, otherwise compute from workspace_id
          volume_name = Keyword.get(agent_opts, :volume) || "code-#{workspace_id}"

          {workspace_id, workspace_id,
           [
             load_config_step(volume_name),
             ensure_services_step(id, workspace_id, working_dir),
             start_agent_step(id, workspace_id, agent_opts, working_dir),
             send_initial_message_step(id, initial_message, service_name)
           ]}
      end

    saga_result =
      Saga.run(steps,
        name: :boot_agent,
        context: %{id: id, workspace_id: workspace_id, scope_key: key},
        metadata: %{agent_id: id, workspace_id: workspace_id, scope_key: inspect(key)},
        # :rollback is the safest default for mid-crash recovery.
        # If the BEAM dies between :start_agent and
        # :send_initial_message, resuming forward would try to re-send
        # the initial message to an agent that may already have
        # processed it (non-idempotent: creates duplicate user
        # messages and confuses Claude). Rolling back instead stops
        # the agent cleanly and surfaces the failure in
        # /system/sagas — the user just retries the boot.
        on_resume: :rollback
      )

    case saga_result do
      {:ok, _ctx} ->
        :ok

      {:error, {:step_failed, step, reason}, rollback_outcome} ->
        Logger.error("[AgentBoot] #{id} saga step #{step} failed: #{inspect(reason)}")

        Loopyard.EventLog.error(
          "agent_boot:#{workspace_id}",
          "boot saga failed at #{step}: #{inspect(reason)} " <>
            "ws_id=#{workspace_id}"
        )

        # Audit LOW #16: surface the rollback_failed path loudly at
        # the call site (not just /system/sagas) so operators see
        # it in logs + telemetry. :rolled_back is benign.
        Saga.maybe_log_rollback_failed(
          rollback_outcome,
          :boot_agent,
          %{agent_id: id, workspace_id: workspace_id}
        )

        ChatAgent.boot_failed(id, reason)
        {:error, reason}
    end
  end

  # --- Saga steps ---

  # Load workspace config from volume. Read-only; no rollback.
  defp load_config_step(volume_name) do
    %{
      name: :load_config,
      run: fn _ctx ->
        ws_config =
          case Workspace.load_from_volume(volume_name) do
            {:ok, ws} -> ws
            _ -> nil
          end

        {:ok, %{ws_config: ws_config}}
      end
    }
  end

  # Ensure services are running. Soft-fail for Setup agents (they
  # exist to FIX the cluster; blocking them on a broken cluster
  # deadlocks the fix path). For every other agent type, compose-up
  # failure halts the saga.
  #
  # Rollback: no-op. Services staying up doesn't leak — the next
  # boot reuses them, and tearing the cluster down because one
  # agent failed to spawn would harm other agents or users on
  # the same workspace.
  defp ensure_services_step(id, workspace_id, working_dir) do
    %{
      name: :ensure_services,
      run: fn _ctx ->
        ws_container =
          Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

        cond do
          # Preview cluster already up — its `workspace` service is the agent's
          # exec target; nothing to do.
          Loopyard.Docker.container_running?(ws_container) ->
            {:ok, %{services_started_here: false}}

          # Working is the default (D10): a volume-backed workspace just needs
          # the cheap, code-mounted WorkContainer — NOT the dev/preview cluster.
          # The agent (or a human) boots preview on demand via the
          # `docker_compose` tool / `Onboarding.start_preview`.
          volume_based?(workspace_id) ->
            ChatAgent.update_boot_status(id, "Preparing workspace...")

            case Workspace.ensure_working(workspace_id) do
              {:ok, _container} ->
                {:ok, %{services_started_here: false}}

              # Boot the agent even if the work container didn't come up, so it
              # can diagnose + fix instead of the whole boot hard-failing into a
              # blank screen. The agent self-determines what's wrong.
              {:error, reason} ->
                Logger.warning(
                  "[AgentBoot] #{id} work container failed; booting anyway so the " <>
                    "agent can diagnose: #{inspect(reason)}"
                )

                {:ok, %{services_started_here: false}}
            end

          # Legacy host bind-mount projects: bring up the compose cluster the
          # agent expects on the host (pre-volume behavior).
          true ->
            ChatAgent.update_boot_status(id, "Starting services...")

            case Workspace.ServiceManager.start_services(working_dir) do
              {:ok, _} ->
                {:ok, %{services_started_here: true}}

              {:error, :service_manager_not_running} ->
                # ServiceManager hasn't been supervised yet — not fatal;
                # start_agent_with_retry below will rebuild the workspace
                # supervisor on first spawn attempt.
                {:ok, %{services_started_here: false}}

              # Boot the agent even if compose failed, so it can fix the cluster
              # rather than the boot hard-failing.
              {:error, reason} ->
                Logger.warning(
                  "[AgentBoot] #{id} compose up failed; booting anyway so the agent " <>
                    "can fix the cluster: #{inspect(reason)}"
                )

                ChatAgent.update_boot_status(id, "Cluster unhealthy — the agent will diagnose")
                {:ok, %{services_started_here: false}}
            end
        end
      end
    }
  end

  defp volume_based?(workspace_id) do
    case Loopyard.WorkspaceRegistry.get_workspace(workspace_id) do
      %{volume_based: true} -> true
      _ -> false
    end
  end

  # A system agent's compute: the identity's workstation container. The name
  # it came up under rides in the ctx for the start step. Hard-fails — there
  # is no system agent without its container.
  defp ensure_workstation_step(id, identity) do
    %{
      name: :ensure_workstation,
      run: fn _ctx ->
        ChatAgent.update_boot_status(id, "Starting the workstation…")

        case workstation_container().ensure_up(identity) do
          {:ok, container} -> {:ok, %{container: container}}
          {:error, reason} -> {:error, {:workstation_container, reason}}
          other -> {:error, {:workstation_container, other}}
        end
      end
    }
  end

  defp workstation_container,
    do: Application.get_env(:loopyard, :workstation_container, Loopyard.Workstation.Container)

  # Spawn the ChatAgent GenServer. Rollback stops it so a
  # later-step failure doesn't leak a running agent. `key` is the scope key:
  # a workspace id, or {:system, identity}.
  defp start_agent_step(id, key, agent_opts, working_dir) do
    %{
      name: :start_agent,
      run: fn ctx ->
        ChatAgent.update_boot_status(id, "Starting Claude session...")

        Logger.info("[AgentBoot] #{id} starting Claude session #{inspect(key)}")

        # The workstation step resolved the container this agent runs in.
        agent_opts =
          case Map.get(ctx, :container) do
            c when is_binary(c) -> Keyword.put(agent_opts, :container, c)
            _ -> agent_opts
          end

        case start_agent_with_retry(key, agent_opts, working_dir) do
          {:ok, pid} ->
            Logger.info("[AgentBoot] #{id} Claude session started successfully")

            Loopyard.EventLog.info(
              "agent_boot:#{scope_label(key)}",
              "Agent #{id} Claude session started"
            )

            {:ok, %{agent_pid: pid}}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      rollback: fn _ctx ->
        # Best-effort — agent may already be gone. stop_agent is
        # a cast-based call in ChatAgent; it's idempotent against
        # missing agents.
        #
        # Audit MEDIUM #11 — rollback UX ordering note:
        # `ChatAgent.stop_agent/1` publishes %Events.ChatAgent.Stopped{}
        # which transitions the sidebar :booting → :stopped (skipping
        # :crashed). The state-machine treats :booting → :stopped as
        # valid so no invariant fails, but the user observably asked
        # to BOOT the agent and will see it transition to :stopped
        # rather than :crashed. This is intentional for now — the
        # rollback fully reverts the :start_agent effect, and
        # `boot_failed/2` is called outside the saga to emit the
        # transient `:chat_agent_boot_failed` event for operator
        # visibility. A dedicated :boot_failed broadcast is a bigger
        # UX scope change; keep current semantics and document so
        # the next person touching this path isn't confused.
        try do
          ChatAgent.stop_agent(id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        :ok
      end
    }
  end

  # Send the initial user message. Fire-and-forget cast; a cast
  # can't fail synchronously. Included as a saga step so the
  # send-or-skip decision is visible in `/system/sagas` alongside
  # the earlier steps.
  defp send_initial_message_step(id, initial_message, service_name) do
    %{
      name: :send_initial_message,
      run: fn ctx ->
        ws_config = Map.get(ctx, :ws_config)

        if initial_message == :none do
          {:ok, %{initial_message: :skipped}}
        else
          msg = initial_message || default_message(ws_config, service_name)
          ChatAgent.send_message(id, msg)
          {:ok, %{initial_message: :sent}}
        end
      end
    }
  end

  # Retry agent spawn once if the workspace supervisor isn't
  # registered. That error is almost always transient — a prior
  # compose-up failure left the group in a partial state, or the
  # supervisor tree was mid-restart when the user clicked. Auto-
  # recover via WorkspaceSupervisor.start_workspace (now handles
  # partial-state rebuilds), then try again. If it still fails,
  # the error bubbles with the real cause.
  defp start_agent_with_retry({:system, identity}, agent_opts, _working_dir) do
    case Loopyard.Agents.SystemGroup.start_agent(identity, agent_opts) do
      {:error, :group_not_running} ->
        with {:ok, _} <- Loopyard.Agents.SystemSupervisor.ensure_group(identity) do
          Loopyard.Agents.SystemGroup.start_agent(identity, agent_opts)
        end

      other ->
        other
    end
  end

  defp start_agent_with_retry(workspace_id, agent_opts, working_dir) do
    case Loopyard.WorkspaceGroup.start_agent(workspace_id, agent_opts) do
      {:error, :workspace_not_running} ->
        Logger.info("[AgentBoot] #{workspace_id} supervisor missing; rebuilding and retrying")

        Loopyard.EventLog.info(
          "agent_boot:#{workspace_id}",
          "Rebuilding workspace supervisor before retrying agent spawn"
        )

        case Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, working_dir) do
          {:ok, _} ->
            Loopyard.WorkspaceGroup.start_agent(workspace_id, agent_opts)

          {:error, reason} ->
            {:error, {:workspace_start_failed, reason}}
        end

      other ->
        other
    end
  end

  defp scope_label({:system, identity}), do: "system:" <> identity
  defp scope_label(ws_id), do: to_string(ws_id)

  # One self-determining kick-off. The agent runs service_containers first and does
  # the right thing — bootstrap if unconfigured, confirm health if already set
  # up — so we don't have to guess "setup vs coding" up front.
  defp default_message(_ws_config, service_name) do
    if service_name do
      "Check the logs for the #{service_name} service and help me debug any issues."
    else
      "Take a look at the workspace in /workspace and get it ready to work on. Run `service_containers` first: " <>
        "if the dev environment isn't set up yet, set it up (read `setup_guide.md` via `read_agent_file` for the playbook, then the matching stack from `stacks/`). " <>
        "If it's already configured and running, just confirm it's healthy and give me a one-line summary of the project."
    end
  end
end
