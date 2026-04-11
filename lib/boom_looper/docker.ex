defmodule BoomLooper.Docker do
  @moduledoc """
  Docker CLI wrapper. Low-level container operations.
  Container orchestration is handled by BoomLooper.Compose.
  """

  @doc "Check if a TCP port has a process listening (not just Docker proxy)."
  def port_open?(port) when is_binary(port), do: port_open?(String.to_integer(port))
  def port_open?(port) when is_integer(port) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        result = case :gen_tcp.recv(socket, 0, 500) do
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
    case docker(["inspect", "-f", "{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Error}}", container_name]) do
      {:ok, output} ->
        case output |> String.trim() |> String.split("|") do
          [status, exit_code, oom, error] ->
            %{
              status: status,
              exit_code: String.to_integer(exit_code),
              oom_killed: oom == "true",
              error: if(error == "", do: nil, else: error)
            }
          _ -> nil
        end
      _ -> nil
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

  @doc "Execute a command in any container by name"
  def exec_in(container_name, command, opts \\ []) do
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 120_000)

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
  List all BoomLooper containers.
  """
  def list_containers(opts \\ []) do
    filter_prefix = Keyword.get(opts, :prefix, "bl-")

    case docker(["ps", "-a", "--filter", "name=#{filter_prefix}",
                  "--format", "{{.Names}}\t{{.Status}}"]) do
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
  Execute a raw docker CLI command. Returns {:ok, output} or {:error, output}.

  Options:
    * `:timeout` — milliseconds (default 120_000)
    * `:env` — list of `{name, value}` tuples passed to the child process
  """
  def docker(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    env = Keyword.get(opts, :env, [])
    cmd_opts = [stderr_to_stdout: true] ++ if(env == [], do: [], else: [env: env])

    task =
      Task.async(fn ->
        System.cmd("docker", args, cmd_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _code}} -> {:error, String.trim(output)}
      nil -> {:error, "Docker command timed out after #{timeout}ms"}
    end
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
  """
  def open_port(args, opts \\ []) do
    case System.find_executable("docker") do
      nil ->
        {:error, "docker not found in PATH"}

      docker_path ->
        port_opts = [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args}
        ]

        port_opts =
          case Keyword.get(opts, :env, []) do
            [] -> port_opts
            env -> port_opts ++ [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
          end

        Port.open({:spawn_executable, docker_path}, port_opts)
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
