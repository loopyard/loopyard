defmodule Hive.Tools.Container do
  @moduledoc """
  Tools for managing Docker containers. Each agent can have its own
  dev environment container for sandboxed code execution.
  """
  use ClaudeCode.MCP.Server, name: "hive-container"

  tool :create, "Create a Docker container for an agent from a Dockerfile path" do
    field :agent_id, :string, required: true
    field :dockerfile_path, :string, required: false
    field :image, :string, required: false

    def execute(%{agent_id: agent_id} = params) do
      container_name = "hive-dev-#{agent_id}"
      image = Map.get(params, :image, "ubuntu:22.04")

      # Build from Dockerfile if provided
      case Map.get(params, :dockerfile_path) do
        nil ->
          :ok

        dockerfile_path ->
          dir = Path.dirname(dockerfile_path)
          file = Path.basename(dockerfile_path)

          case System.cmd("docker", ["build", "-t", container_name, "-f", file, dir],
                 stderr_to_stdout: true
               ) do
            {_, 0} -> :ok
            {output, _} -> {:error, "Docker build failed: #{String.slice(output, 0, 500)}"}
          end
      end

      image_to_use = if Map.has_key?(params, :dockerfile_path), do: container_name, else: image

      case System.cmd(
             "docker",
             ["run", "-d", "--name", container_name, "-w", "/workspace", image_to_use, "sleep", "infinity"],
             stderr_to_stdout: true
           ) do
        {id, 0} -> {:ok, %{container_name: container_name, container_id: String.trim(id)}}
        {output, _} -> {:error, "Docker run failed: #{String.slice(output, 0, 500)}"}
      end
    end
  end

  tool :exec, "Run a command inside an agent's container and return stdout" do
    field :agent_id, :string, required: true
    field :command, :string, required: true

    def execute(%{agent_id: agent_id, command: command}) do
      container_name = "hive-dev-#{agent_id}"

      case System.cmd("docker", ["exec", container_name, "sh", "-c", command],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, "Exit code #{code}: #{String.slice(output, 0, 1000)}"}
      end
    end
  end

  tool :copy_in, "Copy a file from the host into the container" do
    field :agent_id, :string, required: true
    field :host_path, :string, required: true
    field :container_path, :string, required: true

    def execute(%{agent_id: agent_id, host_path: host_path, container_path: container_path}) do
      container_name = "hive-dev-#{agent_id}"

      case System.cmd("docker", ["cp", host_path, "#{container_name}:#{container_path}"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, "Copied #{host_path} to #{container_path}"}
        {output, _} -> {:error, "Copy failed: #{output}"}
      end
    end
  end

  tool :copy_out, "Copy a file from the container to the host" do
    field :agent_id, :string, required: true
    field :container_path, :string, required: true
    field :host_path, :string, required: true

    def execute(%{agent_id: agent_id, container_path: container_path, host_path: host_path}) do
      container_name = "hive-dev-#{agent_id}"

      case System.cmd("docker", ["cp", "#{container_name}:#{container_path}", host_path],
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, "Copied #{container_path} to #{host_path}"}
        {output, _} -> {:error, "Copy failed: #{output}"}
      end
    end
  end

  tool :stop, "Stop and remove an agent's container" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      container_name = "hive-dev-#{agent_id}"
      System.cmd("docker", ["rm", "-f", container_name], stderr_to_stdout: true)
      {:ok, "Container #{container_name} removed"}
    end
  end

  tool :list, "List all running Hive containers" do
    def execute(_params) do
      case System.cmd("docker", ["ps", "--filter", "name=hive-dev", "--format", "{{.Names}}\t{{.Status}}"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          containers =
            output
            |> String.split("\n", trim: true)
            |> Enum.map(fn line ->
              case String.split(line, "\t", parts: 2) do
                [name, status] -> %{name: name, status: status}
                _ -> %{name: line, status: "unknown"}
              end
            end)

          {:ok, containers}

        {output, _} ->
          {:error, "Failed to list containers: #{output}"}
      end
    end
  end
end
