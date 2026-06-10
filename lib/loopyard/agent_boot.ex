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

    agent_type =
      Keyword.get(agent_opts, :agent_type) || Loopyard.Agents.Registry.default_agent_name()

    # Use workspace_id from opts if provided (volume-based workspaces pass it),
    # otherwise compute from path (bind-mount workspaces)
    workspace_id = Keyword.get(agent_opts, :workspace_id) || Workspace.workspace_id(working_dir)

    # Volume-based workspaces pass the volume name, otherwise compute from workspace_id
    volume_name = Keyword.get(agent_opts, :volume) || "code-#{workspace_id}"

    steps = [
      load_config_step(volume_name),
      ensure_services_step(id, workspace_id, working_dir, agent_type),
      start_agent_step(id, workspace_id, agent_opts, working_dir, agent_type),
      send_initial_message_step(id, agent_type, initial_message, service_name)
    ]

    saga_result =
      Saga.run(steps,
        name: :boot_agent,
        context: %{id: id, workspace_id: workspace_id, agent_type: agent_type},
        metadata: %{agent_id: id, workspace_id: workspace_id, agent_type: agent_type},
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
            "ws_id=#{workspace_id} type=#{agent_type}"
        )

        # Audit LOW #16: surface the rollback_failed path loudly at
        # the call site (not just /system/sagas) so operators see
        # it in logs + telemetry. :rolled_back is benign.
        Saga.maybe_log_rollback_failed(
          rollback_outcome,
          :boot_agent,
          %{agent_id: id, workspace_id: workspace_id, agent_type: agent_type}
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
  defp ensure_services_step(id, workspace_id, working_dir, agent_type) do
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

              {:error, reason} when agent_type == "setup" ->
                Logger.warning(
                  "[AgentBoot] #{id} work container failed; booting Setup agent " <>
                    "anyway so it can diagnose: #{inspect(reason)}"
                )

                {:ok, %{services_started_here: false}}

              {:error, reason} ->
                {:error, {:work_container_failed, reason}}
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

              {:error, reason} when agent_type == "setup" ->
                Logger.warning(
                  "[AgentBoot] #{id} compose up failed; booting Setup agent anyway " <>
                    "so it can fix the cluster: #{inspect(reason)}"
                )

                ChatAgent.update_boot_status(
                  id,
                  "Cluster unhealthy — Setup agent will diagnose"
                )

                {:ok, %{services_started_here: false}}

              {:error, reason} ->
                {:error, {:service_start_failed, reason}}
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

  # Spawn the ChatAgent GenServer. Rollback stops it so a
  # later-step failure doesn't leak a running agent.
  defp start_agent_step(id, workspace_id, agent_opts, working_dir, agent_type) do
    %{
      name: :start_agent,
      run: fn _ctx ->
        ChatAgent.update_boot_status(id, "Starting Claude session...")

        Logger.info(
          "[AgentBoot] #{id} starting Claude session ws=#{workspace_id} type=#{agent_type}"
        )

        case start_agent_with_retry(workspace_id, agent_opts, working_dir) do
          {:ok, pid} ->
            Logger.info("[AgentBoot] #{id} Claude session started successfully")

            Loopyard.EventLog.info(
              "agent_boot:#{workspace_id}",
              "Agent #{id} (#{agent_type}) Claude session started"
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
  defp send_initial_message_step(id, agent_type, initial_message, service_name) do
    %{
      name: :send_initial_message,
      run: fn ctx ->
        ws_config = Map.get(ctx, :ws_config)

        if initial_message == :none do
          {:ok, %{initial_message: :skipped}}
        else
          msg = initial_message || default_message(agent_type, ws_config, service_name)

          if msg do
            ChatAgent.send_message(id, msg)
            {:ok, %{initial_message: :sent}}
          else
            {:ok, %{initial_message: :none}}
          end
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

  defp default_message(agent_type, ws_config, service_name) do
    cond do
      service_name ->
        "Check the logs for the #{service_name} service and help me debug any issues."

      agent_type == "setup" ->
        "Look at the project in /workspace and set up a development environment. Start by reading `setup_guide.md` with `read_agent_file` — it has the full playbook. " <>
          "Note: the cluster may not be up yet (compose build can fail if infrastructure files like Dockerfile are missing). Read what's currently in `.loopyard/workspace/` and fix any gaps before re-running compose."

      ws_config && ws_config.dockerfile ->
        "The workspace has an existing configuration. Check `service_status` — if services are running and healthy, you're good. If not, run `rebuild` then install dependencies via `exec`."

      true ->
        nil
    end
  end
end
