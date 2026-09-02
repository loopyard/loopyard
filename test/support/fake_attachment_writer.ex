defmodule Loopyard.Test.FakeAttachmentWriter do
  @moduledoc """
  Stand-in for `Loopyard.VolumeIO` on the attachment WRITE path (`copy_in/3`,
  `write_file/3`). Docker is off in the default suite, so "volumes" are dirs
  under the OS temp dir — cross-process (a LiveView test's view process writes,
  the test process reads), unlike the process-dictionary `FakeVolumeIO`.

  Wired in `config/test.exs` via `:attachment_writer`.
  """

  @root Path.join(System.tmp_dir!(), "loopyard-fake-volumes")

  def copy_in(volume, host_path, dest_abs) do
    target = host(volume, dest_abs)
    File.mkdir_p!(Path.dirname(target))

    case File.cp(host_path, target) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def write_file(volume, path, content) do
    target = host(volume, path)
    File.mkdir_p!(Path.dirname(target))
    File.write(target, content)
  end

  @doc "Read back what a test wrote (absolute `/workspace/...` or volume-relative)."
  def read(volume, path) do
    case File.read(host(volume, path)) do
      {:ok, content} -> content
      {:error, reason} -> {:error, reason}
    end
  end

  defp host(volume, path) do
    rel = path |> Path.expand("/workspace") |> Path.relative_to("/workspace")
    Path.join([@root, volume, rel])
  end
end
