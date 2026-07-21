defmodule Loopyard.Docker do
  @moduledoc """
  Docker CLI wrapper. Low-level container operations.
  Container orchestration is handled by Loopyard.Compose.
  """

  @doc "Check if a TCP port has a process listening (not just Docker proxy)."
  def port_open?(port) when is_binary(port), do: port_open?(String.to_integer(port))

  def port_open?(port) when is_integer(port) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        result =
          case :gen_tcp.recv(socket, 0, 500) do
            {:ok, _data} -> true
            {:error, :timeout} -> true
            {:error, :closed} -> false
          end

        :gen_tcp.close(socket)
        result

      {:error, _} ->
        false
    end
  end

  @doc "Check if a container is running by name"
  def container_running?(container_name) do
    case docker(["inspect", "-f", "{{.State.Running}}", container_name]) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  @doc "Check if a container exists (running or not) by name"
  def container_exists?(container_name) do
    case docker(["inspect", container_name]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc "Get container state details — running, exit code, error, OOM status."
  def container_state(container_name) do
    case docker([
           "inspect",
           "-f",
           "{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Error}}",
           container_name
         ]) do
      {:ok, output} ->
        case output |> String.trim() |> String.split("|") do
          [status, exit_code, oom, error] ->
            %{
              status: status,
              exit_code: String.to_integer(exit_code),
              oom_killed: oom == "true",
              error: if(error == "", do: nil, else: error)
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc "Get the host port mappings for a container. Returns %{container_port => host_port}."
  def container_ports(container_name) do
    case docker(["port", container_name]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          case Regex.run(~r/(\d+)\/\w+\s+->\s+[\d.]+:(\d+)/, line) do
            [_, container_port, host_port] -> {container_port, host_port}
            _ -> {line, nil}
          end
        end)
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Wrap a command so the login profile (`~/.profile`) is sourced before it runs.

  Portable on purpose: plain `sh -c` with an explicit `.` source, so it works on
  busybox ash, dash, and bash alike — no reliance on `-l` or bash being present
  in the target image. This is how a container's identity env (credentials
  written to `~/.loopyard/env` and sourced from `~/.profile`) reaches a command
  WITHOUT putting secrets in `docker run -e` (which leaks them into
  `docker inspect`). See `Loopyard.Workstation.Env.sync_home/1`.
  """
  @spec with_login_profile(String.t()) :: String.t()
  def with_login_profile(command), do: ~s(. "$HOME/.profile" 2>/dev/null\n) <> command

  @doc """
  Execute a command in any container by name.

  Opts: `:workdir`, `:timeout`, and `:login` (default `false`). With `login: true`
  the command is wrapped via `with_login_profile/1` so identity env from the home
  volume is in scope — use it for credential-sensitive commands (the agent's
  shell, the workstation console), not for data-plumbing execs (tar, cat).
  """
  def exec_in(container_name, command, opts \\ []) do
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 120_000)
    command = if Keyword.get(opts, :login, false), do: with_login_profile(command), else: command

    args = ["exec"]
    args = if workdir, do: args ++ ["-w", workdir], else: args
    args = args ++ [container_name, "sh", "-c", command]

    docker(args, timeout: timeout)
  end

  @doc "Get logs from any container by name"
  def container_logs(container_name, opts \\ []) do
    tail = Keyword.get(opts, :tail, 200)
    docker(["logs", "--tail", "#{tail}", container_name], timeout: 5_000)
  end

  @doc """
  List all Loopyard containers.
  """
  def list_containers(opts \\ []) do
    filter_prefix = Keyword.get(opts, :prefix, "loopyard-")

    case docker([
           "ps",
           "-a",
           "--filter",
           "name=#{filter_prefix}",
           "--format",
           "{{.Names}}\t{{.Status}}"
         ]) do
      {:ok, ""} ->
        []

      {:ok, output} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, "\t") do
            [name, status] ->
              running = String.starts_with?(status, "Up")
              %{name: name, status: status, running: running}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Remove orphaned temp containers (alpine, alpine/git) that leaked from
  timed-out VolumeManager operations. `docker run --rm` doesn't fire when
  the Task owning the port is killed, so containers in Created/Exited
  state accumulate. Call this during project teardown and eval cleanup.
  """
  def prune_temp_containers do
    for ancestor <- ["alpine", "alpine/git"] do
      case docker(
             [
               "ps",
               "-a",
               "--filter",
               "ancestor=#{ancestor}",
               "--filter",
               "status=created",
               "--filter",
               "status=exited",
               "--format",
               "{{.ID}}"
             ],
             timeout: 10_000
           ) do
        {:ok, output} ->
          ids = output |> String.trim() |> String.split("\n", trim: true)

          Enum.each(ids, fn id ->
            docker(["rm", "-f", id], timeout: 5_000)
          end)

          length(ids)

        _ ->
          0
      end
    end
    |> Enum.sum()
  end

  @doc """
  Execute a raw docker CLI command. Returns {:ok, output} or {:error, output}.

  Options:
    * `:timeout` — milliseconds (default 120_000)
    * `:env` — list of `{name, value}` tuples passed to the child process
  """
  def docker(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    env = Keyword.get(opts, :env, [])
    retry = Keyword.get(opts, :retry, true)
    cmd_opts = [stderr_to_stdout: true] ++ if(env == [], do: [], else: [env: env])
    # Execution uses the real `args`; telemetry gets a SCRUBBED copy so a
    # token-in-URL (e.g. the `git push https://<token>@github.com` in an
    # integrate) can never leak into /system/events or a future docker-command
    # logger. No consumer logs it today, but redact at the source.
    meta = %{args: scrub_secrets(args), timeout: timeout}

    :telemetry.span([:loopyard, :docker, :command], meta, fn ->
      result = run_with_retry(args, cmd_opts, timeout, retry)
      # `:telemetry.span/3` does NOT merge start_metadata into the stop
      # event — the stop fn is the only source of stop_metadata. Carry
      # `args` and `timeout` forward so subscribers (e.g. /system/events,
      # the docker_test telemetry assertion) get the same context on
      # both span endpoints.
      {result, meta}
    end)
  end

  # Redact URL userinfo (`https://<token>@host` / `https://user:pass@host`) from
  # args before they go into telemetry meta — so a credential-bearing git URL in
  # an integrate/push command can't surface in /system/events or a logger. Only
  # touches the telemetry copy; execution uses the real args. No-op for the
  # common token-free case.
  @userinfo ~r{//[^/@\s]+@}

  @doc false
  def scrub_secrets(args) do
    Enum.map(args, fn
      arg when is_binary(arg) -> String.replace(arg, @userinfo, "//***@")
      other -> other
    end)
  end

  # Retry the docker command iff the failure looks like a *transient*
  # daemon problem — connection refused, dial failures, colima
  # pause/restart. We don't retry:
  #
  #   * timeouts (caller gave us a budget and we burned it)
  #   * non-transient errors like "No such container" (retrying just
  #     delays the real failure and spams the daemon)
  #
  # Three attempts with 100ms/300ms/900ms backoff covers the common
  # "daemon blip" window. Bypass with `retry: false` when a caller
  # wants strict single-shot semantics (e.g. health probes that want
  # the raw truth).
  #
  # Delegates to `Loopyard.Retry` so the schedule math + attempt
  # cap live in one place shared with other retry call sites. See
  # plans/coordination-hardening.md move #7d.
  defp run_with_retry(args, cmd_opts, timeout, false = _retry?) do
    run_once(args, cmd_opts, timeout)
  end

  defp run_with_retry(args, cmd_opts, timeout, true = _retry?) do
    # Retry on any transient error — safe even for mutating commands here
    # because they're all idempotent or double-execute-guarded: `docker run
    # --name` container creation is guarded by WorkContainer.run_idempotent (a
    # retry that races a first-run's lost response hits "name already in use"
    # and is handled); `docker run --rm` calls are one-shots; `volume/network
    # create` are no-ops on an existing resource; `start`/`stop`/`rm -f`/
    # `compose up|down` are idempotent. The resilience of retrying an ambiguous
    # timeout (common under CI Docker load) outweighs a theoretical double-
    # execute. connection_error?/ambiguous_error? remain available if a
    # genuinely non-idempotent command is ever added and needs narrower retry.
    Loopyard.Retry.run(fn -> run_once(args, cmd_opts, timeout) end,
      max_attempts: 3,
      backoff: {:custom, [100, 300, 900]},
      transient?: &transient_error?/1
    )
  end

  defp run_once(args, cmd_opts, timeout) do
    task = Task.async(fn -> System.cmd("docker", args, cmd_opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _code}} -> {:error, String.trim(output)}
      nil -> {:error, "Docker command timed out after #{timeout}ms"}
    end
  end

  # Patterns that indicate the Docker daemon is briefly unreachable,
  # not that the command itself is wrong. Any of these is worth one or
  # two retries; none of them require operator intervention to resolve.
  #
  # Important exception: "dial unix … no such file or directory" means
  # the daemon socket doesn't exist at all (Colima/Docker Desktop is
  # not running). Retrying that 3x with backoff burns ~1.3s per call
  # for nothing — the socket isn't going to materialize on its own.
  # Treat as PERMANENT so the caller fails fast.
  @doc false
  def transient_error?(output) when is_binary(output) do
    connection_error?(output) or ambiguous_error?(output)
  end

  def transient_error?(_), do: false

  # Daemon-unreachable errors: the command provably never executed, so a
  # retry is always safe (even for mutating commands). Socket-missing is
  # excluded — the daemon isn't running and won't materialize.
  @doc false
  def connection_error?(output) when is_binary(output) do
    cond do
      socket_missing?(output) -> false
      String.contains?(output, "Cannot connect to the Docker daemon") -> true
      String.contains?(output, "error during connect") -> true
      String.contains?(output, "dial unix") -> true
      String.contains?(output, "connection refused") -> true
      true -> false
    end
  end

  def connection_error?(_), do: false

  # Errors that can occur AFTER the daemon began executing the command — a
  # dropped response, not proof it didn't run. Safe to retry only for
  # read-only commands.
  @doc false
  def ambiguous_error?(output) when is_binary(output) do
    String.contains?(output, "i/o timeout") or
      String.contains?(output, "EOF") or
      String.contains?(output, "request canceled")
  end

  def ambiguous_error?(_), do: false

  defp socket_missing?(output) do
    String.contains?(output, "dial unix") and
      String.contains?(output, "no such file or directory")
  end

  @doc """
  Stream a docker command, invoking `callback` with each chunk of output.
  Returns `{:ok, full_output}` on exit 0, or `{:error, partial_output}` on
  non-zero exit / timeout.

  Options:
    * `:timeout` — total max wait (default 600_000)
  """
  def stream(args, callback, opts \\ []) when is_function(callback, 1) do
    timeout = Keyword.get(opts, :timeout, 600_000)

    case open_port(args) do
      {:error, _} = err -> err
      port -> collect_stream(port, callback, "", timeout)
    end
  end

  @doc """
  Open a raw `Port` for a docker command. Caller is responsible for
  receiving port messages and closing the port.

  Options:
    * `:env` — list of `{name, value}` tuples passed to the child process
    * `:watchdog` — spawn via a stdin-watchdog shell that KILLS the docker
      client when the port goes away (default `false`).

  ## Why `:watchdog` exists (the 148-orphan incident)

  Closing an Erlang port only closes the child's stdio pipes — it does NOT
  kill the process. A read-only follower like `docker logs -f` on a QUIET
  container never writes, so it never hits EPIPE and lives forever: every
  LogBuffer/owner restart, and every full-VM reboot, orphaned one follower
  per service until the accumulated clients exhausted Colima's docker socket
  (EOF on every new connection). With `:watchdog`, the wrapper's `cat` sees
  stdin EOF the moment the port dies — owner crash, Port.close, or whole-BEAM
  death alike — and kills the docker client. Use it for every follower that
  doesn't need stdin (`logs -f`, `events`); NOT for interactive ports (the
  terminal writes keystrokes through stdin, which the watchdog would eat).
  """
  def open_port(args, opts \\ []) do
    case System.find_executable("docker") do
      nil ->
        {:error, "docker not found in PATH"}

      docker_path ->
        port_opts = [
          :binary,
          :exit_status,
          :stderr_to_stdout
        ]

        port_opts =
          case Keyword.get(opts, :env, []) do
            [] ->
              port_opts

            env ->
              port_opts ++
                [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
          end

        if Keyword.get(opts, :watchdog, false) do
          # `$0` is the docker path, `"$@"` the args; docker's stdout/stderr
          # inherit the shell's, so output flows to the port unchanged. `cat`
          # holds the shell on stdin until the port dies, then the client is
          # killed — no orphan survives its port.
          script = ~S("$0" "$@" & p=$!; cat >/dev/null 2>&1; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null)

          Port.open(
            {:spawn_executable, System.find_executable("sh")},
            port_opts ++ [{:args, ["-c", script, docker_path | args]}]
          )
        else
          Port.open({:spawn_executable, docker_path}, port_opts ++ [{:args, args}])
        end
    end
  end

  defp collect_stream(port, callback, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        callback.(data)
        collect_stream(port, callback, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, _}} ->
        {:error, acc}
    after
      timeout ->
        Port.close(port)
        {:error, acc <> "\n(timed out)"}
    end
  end
end
