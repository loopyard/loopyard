defmodule Loopyard.ContainerIO do
  @moduledoc """
  File I/O against a RUNNING container by absolute path — the sibling of
  `Loopyard.VolumeIO` for filesystems that aren't a `/workspace` code volume
  (the operator's workstation `$HOME`, say).

  Three verbs, all through the Docker CLI: `copy_in/3` streams a host file in
  with `docker cp` (no ARG_MAX ceiling, binary-safe), `write_file/3` drops a
  small text file via `exec`, `read_file/2` cats one back. Paths must be
  absolute; there is no confinement here — the caller picks the container and
  the directory, and every caller today is a Loopyard-owned path
  (`<home>/.loopyard/uploads`), never user input.

  Injectable for tests via `config :loopyard, :container_io`.
  """

  alias Loopyard.Docker

  @spec copy_in(String.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def copy_in(container, host_path, dest) do
    with :ok <- absolute!(dest),
         true <- File.regular?(host_path) || {:error, :enoent},
         {:ok, _} <- Docker.exec_in(container, "mkdir -p #{shq(Path.dirname(dest))}"),
         {:ok, _} <- Docker.docker(["cp", host_path, "#{container}:#{dest}"]) do
      :ok
    end
  end

  @spec write_file(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(container, path, content) do
    with :ok <- absolute!(path),
         {:ok, _} <-
           Docker.exec_in(
             container,
             "mkdir -p #{shq(Path.dirname(path))} && echo '#{Base.encode64(content)}' | base64 -d > #{shq(path)}"
           ) do
      :ok
    end
  end

  @spec read_file(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(container, path) do
    with :ok <- absolute!(path) do
      Docker.exec_in(container, "cat #{shq(path)}")
    end
  end

  defp absolute!(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.contains?(path, <<0>>),
      do: :ok,
      else: {:error, :invalid_path}
  end

  defp absolute!(_), do: {:error, :invalid_path}

  defp shq(s), do: "'" <> String.replace(s, "'", "'\"'\"'") <> "'"
end
