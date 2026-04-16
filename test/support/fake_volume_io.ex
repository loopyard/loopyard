defmodule BoomLooper.Test.FakeVolumeIO do
  @moduledoc """
  In-process stand-in for `BoomLooper.VolumeIO` used by ClaudeContext
  tests. Read calls hit the process dictionary so tests can seed an
  arbitrary "volume" without touching Docker.

  Tests swap the real module in via:

      Application.put_env(:boom_looper, :volume_reader,
        BoomLooper.Test.FakeVolumeIO)
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
    for {path, content} <- files do
      Process.put({__MODULE__, volume, path}, content)
    end

    volume
  end
end
