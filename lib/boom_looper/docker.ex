defmodule BoomLooper.Docker do
  @moduledoc """
  Docker CLI wrapper. Low-level container operations.
  Container orchestration is handled by BoomLooper.Compose.
  """

  @dockerfile """
  FROM ubuntu:24.04
  ENV DEBIAN_FRONTEND=noninteractive

  RUN apt-get update && apt-get install -y \\
      git build-essential ca-certificates gnupg curl \\
      && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \\
         | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \\
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \\
         | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \\
      && apt-get update && apt-get install -y gh \\
      && rm -rf /var/lib/apt/lists/*

  WORKDIR /workspace
  CMD ["sleep", "infinity"]
  """

  @doc "Returns the default Dockerfile content"
  def dockerfile, do: @dockerfile

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

  @doc "Execute a raw docker CLI command. Returns {:ok, output} or {:error, output}."
  def docker(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    task =
      Task.async(fn ->
        System.cmd("docker", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _code}} -> {:error, String.trim(output)}
      nil -> {:error, "Docker command timed out after #{timeout}ms"}
    end
  end
end
