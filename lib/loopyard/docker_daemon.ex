defmodule Loopyard.DockerDaemon do
  @moduledoc """
  The container runtime's KEEPER — Loopyard owns its Docker daemon the way it
  owns everything else: probe it, and when it dies, FIX it (this fucker can
  deal with problems remotely). Entirely userland: `colima` runs VMs as the
  user; the only `sudo` is inside the VM (the inotify sysctl), never on the
  host.

  * Probe: `docker version` every #{10}s (5s guard — a dead socket can hang).
  * Two consecutive failures → the daemon is DOWN:
      - `:persistent_term` flag flips (`up?/0`) so noisy per-agent restart
        errors go EventLog-only while the real cause is the runtime;
      - ONE calm operator-chat line + a web push ("proper notification");
      - AUTOHEAL: `colima stop -f` then `colima start` (bounded attempts).
        This also means a stopped runtime at SERVER BOOT gets started —
        the server manages the instance, not the human.
  * Recovery: silent in chat (the outage line promised auto-resume); the
    inotify limit is re-applied inside the VM (lost on every VM restart —
    without it ACP `session/new` hangs once 128 watchers saturate), and every
    workspace's compose cluster is re-upped (a daemon restart kills all
    containers and compose never restarts itself).
  * Heal exhausted → one decisive line + push with the human's single move.

  Test seams: `:docker_probe_fun` / `:docker_heal_fun` app config (same
  injection pattern as `:mutagen_runner`); `:docker_probe_ms` nil disables
  the timer entirely (test env).
  """
  use GenServer

  @probe_ms 10_000
  @fail_threshold 2
  @heal_attempts 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Is the Docker daemon reachable (last probe verdict)? Optimistic default."
  def up?, do: :persistent_term.get({__MODULE__, :up}, true)

  @impl true
  def init(_opts) do
    :persistent_term.put({__MODULE__, :up}, true)

    case probe_interval() do
      nil -> :ok
      # First probe fast: a stopped runtime at server boot gets healed
      # immediately instead of 10s later.
      _ms -> Process.send_after(self(), :probe, 1_000)
    end

    {:ok, %{status: :up, fails: 0, heal_attempts: 0, announced: false}}
  end

  @impl true
  def handle_info(:probe, state) do
    state =
      case probe() do
        :ok -> handle_up(state)
        :error -> handle_down(state)
      end

    if ms = probe_interval(), do: Process.send_after(self(), :probe, ms)
    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── transitions ──────────────────────────────────────────────────────────

  defp handle_up(%{status: :up} = state), do: %{state | fails: 0}

  defp handle_up(state) do
    # RECOVERED. Silent in chat (the outage line promised auto-resume);
    # EventLog carries it. Re-apply the in-VM inotify limit — lost on every
    # VM restart, and without it ACP session/new eventually hangs.
    :persistent_term.put({__MODULE__, :up}, true)
    Loopyard.EventLog.info("docker", "daemon recovered — agents resume on their own")
    reapply_inotify()
    revive_services()
    %{state | status: :up, fails: 0, heal_attempts: 0, announced: false}
  end

  defp handle_down(state) do
    fails = state.fails + 1

    cond do
      fails < @fail_threshold ->
        %{state | fails: fails}

      state.status == :up ->
        declare_down(%{state | fails: fails})

      state.heal_attempts < @heal_attempts ->
        heal(%{state | fails: fails})

      not state.announced ->
        give_up(%{state | fails: fails})

      true ->
        %{state | fails: fails}
    end
  end

  defp declare_down(state) do
    :persistent_term.put({__MODULE__, :up}, false)
    Loopyard.EventLog.error("docker", "daemon unreachable — attempting restart")

    # ONE calm line where the human is looking + the pocket notification.
    # The restart takes ~a minute — that's the "takes a while" case that
    # earns a chat line.
    operator_note(
      "Docker died — restarting the container runtime. Agents pause and " <>
        "resume on their own (about a minute)."
    )

    Loopyard.WebPush.notify_question(
      "Docker crashed",
      "Restarting the container runtime — agents resume automatically.",
      "/system"
    )

    heal(%{state | status: :down})
  end

  defp heal(state) do
    attempt = state.heal_attempts + 1
    Loopyard.EventLog.warning("docker", "runtime restart attempt #{attempt}/#{@heal_attempts}")

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn -> heal_fun().() end)

    %{state | heal_attempts: attempt}
  end

  defp give_up(state) do
    Loopyard.EventLog.error("docker", "runtime restart failed #{@heal_attempts}x — human needed")

    operator_note(
      "This didn't self-heal — Docker's runtime wouldn't restart " <>
        "(#{@heal_attempts} attempts). Run `colima start` on the Mac; " <>
        "everything resumes on its own once it's back."
    )

    Loopyard.WebPush.notify_question(
      "Docker is still down",
      "Auto-restart failed — run `colima start` on the Mac.",
      "/system"
    )

    %{state | announced: true}
  end

  # ── plumbing ─────────────────────────────────────────────────────────────

  defp probe do
    fun =
      Application.get_env(:loopyard, :docker_probe_fun, fn ->
        task =
          Task.Supervisor.async_nolink(Loopyard.TaskSupervisor, fn ->
            System.cmd("docker", ["version", "--format", "{{.Server.Version}}"],
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, 5_000) || Task.shutdown(task) do
          {:ok, {_out, 0}} -> :ok
          _ -> :error
        end
      end)

    fun.()
  rescue
    _ -> :error
  end

  # Userland heal: colima VMs run as the user — no host sudo anywhere.
  defp heal_fun do
    Application.get_env(:loopyard, :docker_heal_fun, fn ->
      if System.find_executable("colima") do
        _ = cmd_yield("colima", ["stop", "-f"], 60_000)
        _ = cmd_yield("colima", ["start"], 240_000)
        :ok
      else
        Loopyard.EventLog.warning("docker", "no colima binary — cannot autoheal")
        :error
      end
    end)
  end

  # A daemon restart kills every container, and compose clusters don't come
  # back on their own — "everything is crashed out" in the sidebar. Re-up
  # every workspace that HAS a compose config (idempotent; ServiceManager
  # no-ops when already running). Agents/work containers self-heal separately.
  defp revive_services do
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      for p <- Loopyard.ProjectRegistry.list_projects(),
          ws <- Loopyard.WorkspaceRegistry.list_workspaces(p.id),
          compose =
            Path.join([
              Loopyard.Workspace.compose_dir(ws.id),
              ".loopyard",
              "workspace",
              "docker-compose.yml"
            ]),
          File.exists?(compose) do
        Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
          # Group first: an unregistered ServiceManager silently swallows the
          # resync ({:error, :service_manager_not_running}).
          _ = Loopyard.WorkspaceSupervisor.start_workspace(ws.id, ws.path)
          _ = Loopyard.Workspace.ServiceManager.resync_services(ws.path)

          # LESSON FROM THE FIELD: infra revival can't fix an APP-level break
          # (garryslist crash-looped on Bundler::GemNotFound after a clean
          # resync, and sat red until a human noticed the pills). Give the
          # cluster a minute to settle, then hand any still-crashing service —
          # WITH its log tail — to the workspace's own agent. The agent owns
          # its dev environment; the machinery's job is a good handoff.
          Process.sleep(60_000)
          dispatch_crash_loops(ws)
        end)
      end

      :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp dispatch_crash_loops(ws) do
    {:ok, out} =
      Loopyard.Docker.docker([
        "ps",
        "-a",
        "--filter",
        "name=loopyard-#{ws.id}",
        "--format",
        "{{.Names}}|{{.Status}}"
      ])

    crashed =
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "Exited"))
      |> Enum.map(&hd(String.split(&1, "|")))
      |> Enum.reject(&String.ends_with?(&1, "-work"))

    if crashed != [] do
      diagnosis =
        Enum.map_join(crashed, "\n\n", fn name ->
          tail =
            case Loopyard.Docker.docker(["logs", "--tail", "15", name]) do
              {:ok, logs} -> logs
              _ -> "(no logs)"
            end

          "#{name}:\n#{tail}"
        end)

      agent =
        Loopyard.ChatAgent.list_agent_summaries()
        |> Enum.find(&(&1[:workspace_id] == ws.id))

      if agent do
        Loopyard.ChatAgent.enqueue_message(
          agent.id,
          "Docker was restarted and your dev cluster came back — except these " <>
            "services, which are crash-looping (likely an app-level issue: " <>
            "stale deps, migrations, config). Diagnose from the logs below and " <>
            "bring them up.\n\n#{diagnosis}"
        )

        Loopyard.EventLog.warning(
          "docker",
          "post-revive crash-loops in #{ws.id} handed to its agent"
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp reapply_inotify do
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      if System.find_executable("colima") do
        _ =
          cmd_yield(
            "colima",
            ["ssh", "--", "sudo", "sysctl", "-w", "fs.inotify.max_user_instances=1024"],
            30_000
          )
      end

      :ok
    end)
  end

  defp cmd_yield(bin, args, timeout) do
    task =
      Task.Supervisor.async_nolink(Loopyard.TaskSupervisor, fn ->
        System.cmd(bin, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      _ -> {:error, :timeout}
    end
  end

  defp operator_note(text) do
    case Loopyard.Operator.agent_id() do
      id when is_binary(id) ->
        note = %{role: :system, content: text, timestamp: DateTime.utc_now()}
        _ = Loopyard.ChatAgent.MessageWindow.append_message_ets(id, note)

        Loopyard.Events.ChatAgentMessage.publish(%Loopyard.Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: Map.put_new(note, :id, "docker-#{System.unique_integer([:positive])}")
        })

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp probe_interval, do: Application.get_env(:loopyard, :docker_probe_ms, @probe_ms)
end
