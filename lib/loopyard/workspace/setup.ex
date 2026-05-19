defmodule Loopyard.Workspace.Setup do
  @moduledoc """
  Coordinator for the workspace setup saga.

  When `WorkspaceRegistry.add_workspace/2` runs, the workspace map lands
  in ETS at `setup.phase: :pending`. This coordinator spawns a Task that
  runs the saga in the background; the workspace transitions to `:ready`
  (or `:failed`) via PubSub events that the LiveView re-renders on.

  Three phases:

    * `:worktree` — adapter creates the source-of-truth tree. Local: host
      git worktree + `.loopyard` config copy. GitHub (PR2): host git
      clone into a tmp dir.
    * `:volume`   — `docker volume create` (idempotent for both adapters).
    * `:seeding`  — adapter rsyncs / copies code INTO the volume so the
      workspace is browsable BEFORE the cluster is up. Slow phase.

  The coordinator is **stateless**. It spawns supervised Tasks under
  `Loopyard.TaskSupervisor` and uses `Workspace.Setup.Registry` to
  suppress duplicate runs and let the destructor cancel an in-flight
  setup.

  ## Public API

    * `start/1` — kick off setup for a workspace at `phase: :pending`.
      Idempotent: returns `{:error, :already_running}` if a setup task
      is already alive for this workspace.
    * `retry/1` — re-run the saga for a workspace at `phase: :failed`.
      Bumps `attempts` and starts a fresh Task. Each phase is idempotent
      so re-running the whole saga is safe.
    * `cancel/1` — kill the in-flight task. Used by Destructor.
    * `in_progress?/1` — Registry lookup; cheap.

  ## Events

  See `Loopyard.Events.WorkspaceSetup`. The saga publishes:

    * `Started` once per attempt.
    * `PhaseStarted` / `PhaseCompleted` around each phase.
    * `PhaseProgress` (during `:seeding`) with rsync output payload.
    * `RetryScheduled` between transient retries within a phase.
    * `Completed` on terminal-success.
    * `Failed` on terminal-failure (carries structured `Error` map).

  ## Recovery on restart

  See `recover_on_boot/0`. Any workspace at a non-terminal setup phase
  when the BEAM restarts gets transitioned to `:failed` with
  `error.code: :interrupted_by_restart`. The user clicks Retry to resume.
  We deliberately do NOT auto-resume — host paths can move, partial state
  can confuse retries, and surfacing the situation in the UI keeps the
  operator in the loop.
  """

  require Logger

  alias Loopyard.{Saga, WorkspaceRegistry}
  alias Loopyard.Workspace.Setup.Error
  alias Loopyard.Events.WorkspaceSetup

  alias Loopyard.Events.WorkspaceSetup.{
    Started,
    PhaseStarted,
    PhaseCompleted,
    PhaseProgress,
    Completed,
    Failed,
    RetryScheduled
  }

  @registry __MODULE__.Registry

  # Saga phase order. The order matters — :worktree before :volume before
  # :seeding — and the SetupProgress UI uses the same order to render the
  # step list.
  @phases [:worktree, :volume, :seeding]

  # Phases that have non-terminal status while the saga is alive. Used by
  # `recover_on_boot/0` to find sagas interrupted by BEAM restart.
  @non_terminal_phases [:running | @phases]

  def phases, do: @phases

  # ── Public API ──

  @doc """
  Start the setup saga for `workspace_id`. Returns `:ok` (task spawned),
  `{:error, :already_running}`, or `{:error, :not_found}`.
  """
  def start(workspace_id) when is_binary(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      nil ->
        {:error, :not_found}

      _ws ->
        spawn_setup_task(workspace_id, attempt: 1)
    end
  end

  @doc """
  Retry a failed setup. Reads `attempts` from the current setup state,
  increments, and spawns a fresh task.
  """
  def retry(workspace_id) when is_binary(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      %{setup: %{phase: :failed, attempts: attempts}} ->
        WorkspaceRegistry.update_setup(workspace_id, %{
          phase: :pending,
          error: nil
        })

        case spawn_setup_task(workspace_id, attempt: attempts + 1) do
          :ok ->
            :ok

          {:error, :already_running} ->
            # Another retry won the race; revert the phase change.
            WorkspaceRegistry.update_setup(workspace_id, %{
              phase: :failed
            })

            {:error, :already_running}
        end

      %{setup: %{phase: phase}} ->
        {:error, {:not_failed, phase}}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Returns true if a setup task is currently running for this workspace."
  def in_progress?(workspace_id) when is_binary(workspace_id) do
    match?([{_pid, _}], Registry.lookup(@registry, workspace_id))
  end

  @doc """
  Cancel an in-flight setup. Used by `Workspace.Destructor.destroy/1`.
  Best-effort: returns `:ok` whether or not a task was actually running.
  """
  def cancel(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] ->
        Process.exit(pid, :shutdown)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Mark any workspace at a non-terminal setup phase as `:failed` with
  `error.code: :interrupted_by_restart`. Called from app boot after
  `WorkspaceRegistry`/ETS have been restored.
  """
  def recover_on_boot do
    workspaces = :ets.tab2list(:workspace_registry) |> Enum.map(fn {_id, w} -> w end)

    Enum.reduce(workspaces, 0, fn ws, acc ->
      case Map.get(ws, :setup) do
        %{phase: phase} when phase in @non_terminal_phases ->
          interrupted_failure(ws.id, phase)
          acc + 1

        _ ->
          acc
      end
    end)
  end

  @doc false
  def initial_setup_field do
    %{
      phase: :pending,
      attempts: 0,
      error: nil,
      started_at: nil,
      finished_at: nil,
      progress: nil
    }
  end

  @doc false
  def ready_setup_field do
    %{
      phase: :ready,
      attempts: 0,
      error: nil,
      started_at: nil,
      finished_at: DateTime.utc_now(),
      progress: nil
    }
  end

  # ── Saga runner ──

  defp spawn_setup_task(workspace_id, opts) do
    caller = self()
    ref = make_ref()

    Task.Supervisor.start_child(
      Loopyard.TaskSupervisor,
      fn ->
        case Registry.register(@registry, workspace_id, %{}) do
          {:ok, _} ->
            send(caller, {ref, :registered})
            run_saga(workspace_id, opts)

          {:error, {:already_registered, _}} ->
            send(caller, {ref, :already_running})
        end
      end,
      restart: :temporary
    )

    # Wait for the task to report whether it acquired the lock.
    # Short timeout — registration is near-instant.
    receive do
      {^ref, :registered} -> :ok
      {^ref, :already_running} -> {:error, :already_running}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp run_saga(workspace_id, opts) do
    attempt = Keyword.get(opts, :attempt, 1)
    project_id = workspace_project_id(workspace_id)
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:millisecond)

    transition_to_running(workspace_id, attempt, started_at)

    WorkspaceSetup.publish(%Started{
      workspace_id: workspace_id,
      project_id: project_id,
      attempt: attempt,
      started_at: started_at
    })

    try do
      saga_steps = [
        %{
          name: :worktree,
          run: fn ctx -> run_phase(:worktree, ctx) end
        },
        %{
          name: :volume,
          run: fn ctx -> run_phase(:volume, ctx) end,
          rollback: fn ctx ->
            volume_name = Loopyard.Workspace.volume_name_for(ctx.workspace_id)

            case Loopyard.VolumeManager.delete_volume(volume_name) do
              :ok ->
                Logger.info("[Workspace.Setup] rolled back volume #{volume_name}")
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[Workspace.Setup] best-effort volume rollback failed for #{volume_name}: #{inspect(reason)}"
                )

                :ok
            end
          end
        },
        %{
          name: :seeding,
          run: fn ctx -> run_phase(:seeding, ctx) end
        }
      ]

      saga_result =
        Saga.run(saga_steps,
          name: :workspace_setup,
          context: %{workspace_id: workspace_id},
          metadata: %{workspace_id: workspace_id, attempt: attempt}
        )

      finalize_saga(saga_result, workspace_id, started_mono)
    rescue
      exception ->
        error = Error.classify({:exception, Exception.message(exception)}, :unexpected_crash)

        WorkspaceRegistry.update_setup(workspace_id, %{
          phase: :failed,
          finished_at: DateTime.utc_now(),
          error: error,
          progress: nil
        })

        WorkspaceSetup.publish(%Failed{
          workspace_id: workspace_id,
          phase: :unexpected_crash,
          error: error
        })

        Logger.warning(
          "[Workspace.Setup] run_saga crashed for #{workspace_id}: #{Exception.message(exception)}"
        )
    catch
      kind, reason ->
        error = Error.classify({kind, reason}, :unexpected_crash)

        WorkspaceRegistry.update_setup(workspace_id, %{
          phase: :failed,
          finished_at: DateTime.utc_now(),
          error: error,
          progress: nil
        })

        WorkspaceSetup.publish(%Failed{
          workspace_id: workspace_id,
          phase: :unexpected_crash,
          error: error
        })

        Logger.warning(
          "[Workspace.Setup] run_saga crashed for #{workspace_id}: #{inspect({kind, reason})}"
        )
    end
  end

  # ── Per-phase runner ──

  # `phase` is constrained to the three atoms in @phases (:worktree |
  # :volume | :seeding) — Sobelow can't see the constraint statically.
  @sobelow_skip ["DOS.BinToAtom"]
  defp run_phase(phase, ctx) do
    workspace_id = ctx.workspace_id
    phase_started_at = DateTime.utc_now()
    phase_started_mono = System.monotonic_time(:millisecond)

    update_phase(workspace_id, phase)

    WorkspaceSetup.publish(%PhaseStarted{
      workspace_id: workspace_id,
      phase: phase,
      started_at: phase_started_at
    })

    result =
      Loopyard.Retry.run(
        fn -> invoke_phase(phase, workspace_id) end,
        max_attempts: 3,
        backoff: {:exponential, 1_000},
        transient?: fn reason ->
          err = Error.classify(reason, phase)

          if err.transient? do
            WorkspaceSetup.publish(%RetryScheduled{
              workspace_id: workspace_id,
              phase: phase,
              attempt: 1,
              delay_ms: Loopyard.Retry.backoff_ms(1, {:exponential, 1_000}),
              scheduled_at: DateTime.utc_now()
            })

            true
          else
            false
          end
        end
      )

    case result do
      {:ok, payload} ->
        publish_phase_completed(workspace_id, phase, phase_started_mono)
        {:ok, Map.put(%{}, :"#{phase}_payload", payload)}

      :ok ->
        publish_phase_completed(workspace_id, phase, phase_started_mono)
        {:ok, %{}}

      {:error, _reason} = err ->
        err
    end
  end

  defp publish_phase_completed(workspace_id, phase, phase_started_mono) do
    duration_ms = System.monotonic_time(:millisecond) - phase_started_mono

    WorkspaceSetup.publish(%PhaseCompleted{
      workspace_id: workspace_id,
      phase: phase,
      duration_ms: duration_ms,
      finished_at: DateTime.utc_now()
    })
  end

  # Dispatch a phase through the workspace's adapter.
  defp invoke_phase(phase, workspace_id) do
    with %{} = workspace <- WorkspaceRegistry.get_workspace(workspace_id),
         project when not is_nil(project) <-
           Loopyard.ProjectRegistry.get_project(workspace.project_id) do
      adapter = Loopyard.Source.for_project(project)
      do_invoke_phase(phase, adapter, workspace, workspace_id)
    else
      nil -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp do_invoke_phase(:worktree, adapter, workspace, _workspace_id) do
    adapter.do_create_worktree(workspace)
  end

  defp do_invoke_phase(:volume, adapter, workspace, _workspace_id) do
    adapter.do_create_volume(workspace)
  end

  defp do_invoke_phase(:seeding, adapter, workspace, workspace_id) do
    # Idempotency: skip the seed if the sentinel is already present.
    # Different from `volume_has_code?` (which checks `.git/objects` and
    # would always say "no" for Local since rsync excludes that path).
    if is_binary(workspace[:volume]) and Loopyard.VolumeIO.seeded?(workspace.volume) do
      :ok
    else
      callback = make_progress_callback(workspace_id)
      adapter.do_seed_volume(workspace, callback, [])
    end
  end

  # The seed callback receives stdout+stderr chunks from rsync. We feed
  # each chunk into the progress parser, debounce, and broadcast.
  defp make_progress_callback(workspace_id) do
    {:ok, agent} = Agent.start_link(fn -> %{last_emit: 0, last_payload: nil} end)

    fn chunk when is_binary(chunk) ->
      case Loopyard.Workspace.Setup.ProgressParser.parse_rsync_chunk(chunk) do
        nil ->
          :ok

        payload ->
          now = System.monotonic_time(:millisecond)

          should_emit =
            Agent.get_and_update(agent, fn state ->
              if now - state.last_emit >= 250 or payload != state.last_payload do
                {true, %{last_emit: now, last_payload: payload}}
              else
                {false, state}
              end
            end)

          if should_emit do
            WorkspaceRegistry.update_setup(workspace_id, %{progress: payload})

            WorkspaceSetup.publish(%PhaseProgress{
              workspace_id: workspace_id,
              phase: :seeding,
              payload: payload
            })
          end

          :ok
      end
    end
  end

  defp finalize_saga({:ok, _ctx}, workspace_id, started_mono) do
    finished_at = DateTime.utc_now()
    total_duration_ms = System.monotonic_time(:millisecond) - started_mono

    WorkspaceRegistry.update_setup(workspace_id, %{
      phase: :ready,
      finished_at: finished_at,
      error: nil,
      progress: nil
    })

    WorkspaceSetup.publish(%Completed{
      workspace_id: workspace_id,
      total_duration_ms: total_duration_ms,
      finished_at: finished_at
    })
  end

  defp finalize_saga({:error, {:step_failed, step, reason}, _rb}, workspace_id, _started_mono) do
    error = Error.classify(reason, step)

    WorkspaceRegistry.update_setup(workspace_id, %{
      phase: :failed,
      finished_at: DateTime.utc_now(),
      error: error,
      progress: nil
    })

    WorkspaceSetup.publish(%Failed{
      workspace_id: workspace_id,
      phase: step,
      error: error
    })

    Logger.warning(
      "[Workspace.Setup] saga failed for #{workspace_id} at #{step}: #{error.code} — #{error.why}"
    )
  end

  # ── State transitions ──

  defp transition_to_running(workspace_id, attempt, started_at) do
    WorkspaceRegistry.update_setup(workspace_id, %{
      phase: :running,
      attempts: attempt,
      started_at: started_at,
      finished_at: nil,
      error: nil,
      progress: nil
    })
  end

  defp update_phase(workspace_id, phase) do
    WorkspaceRegistry.update_setup(workspace_id, %{phase: phase})
  end

  defp interrupted_failure(workspace_id, prior_phase) do
    error = Error.classify(:interrupted_by_restart, prior_phase)

    WorkspaceRegistry.update_setup(workspace_id, %{
      phase: :failed,
      finished_at: DateTime.utc_now(),
      error: error,
      progress: nil
    })

    WorkspaceSetup.publish(%Failed{
      workspace_id: workspace_id,
      phase: prior_phase,
      error: error
    })

    Logger.warning(
      "[Workspace.Setup] #{workspace_id} marked failed on boot: interrupted by restart"
    )
  end

  defp workspace_project_id(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      %{project_id: pid} -> pid
      _ -> nil
    end
  end
end
