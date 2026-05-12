defmodule Loopyard.Test.FakeVolumeIO do
  @moduledoc """
  In-process stand-in for `Loopyard.VolumeIO` used by ClaudeContext
  tests. Read calls hit the process dictionary so tests can seed an
  arbitrary "volume" without touching Docker.

  Tests swap the real module in via:

      Application.put_env(:loopyard, :volume_reader,
        Loopyard.Test.FakeVolumeIO)
  """

  def read_file(volume, path) do
    case Process.get({__MODULE__, volume, path}) do
      nil -> {:error, :not_found}
      "" -> {:error, :not_found}
      content when is_binary(content) -> {:ok, content}
    end
  end

  @doc """
  Seed a fake volume. Pass a list of `{relative_path, content}` pairs;
  returns the volume name to pass wherever a real code volume would go.
  """
  def seed(volume, files) when is_list(files) do
    Process.put({__MODULE__, :volume_files, volume}, Enum.map(files, fn {p, _} -> p end))

    for {path, content} <- files do
      Process.put({__MODULE__, volume, path}, content)
    end

    volume
  end

  @doc """
  Walk the seeded files and write any that live under `src_rel` into
  `dest_abs`, preserving relative paths.
  """
  def mirror_dir(volume, src_rel, dest_abs) do
    paths = Process.get({__MODULE__, :volume_files, volume}, [])

    for path <- paths, under?(path, src_rel) do
      content = Process.get({__MODULE__, volume, path})
      target = Path.join(dest_abs, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end

    :ok
  end

  defp under?(_path, "."), do: true

  defp under?(path, prefix) do
    String.starts_with?(path, prefix <> "/") or path == prefix
  end
end
