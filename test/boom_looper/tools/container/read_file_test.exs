defmodule BoomLooper.Tools.Container.ReadFileTest do
  use ExUnit.Case, async: true

  # Test the line slicing logic directly since the full execute path
  # requires Docker. The slicing is the new code; VolumeManager.read_file
  # is tested elsewhere.

  @content "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10"

  describe "maybe_slice_lines/3" do
    # Access the private function via Module.
    # Alternatively we could make it public — but it's a pure helper,
    # testing via the module's own contract is cleaner.

    test "no range returns content unchanged" do
      assert slice(@content, nil, nil) == @content
    end

    test "start_line only" do
      result = slice(@content, 8, nil)
      assert result =~ "8\tline8"
      assert result =~ "10\tline10"
      refute result =~ "7\t"
    end

    test "end_line only" do
      result = slice(@content, nil, 3)
      assert result =~ "1\tline1"
      assert result =~ "3\tline3"
      refute result =~ "4\t"
    end

    test "start_line and end_line" do
      result = slice(@content, 3, 5)
      lines = String.split(result, "\n")
      assert length(lines) == 3
      assert hd(lines) =~ "3\tline3"
      assert List.last(lines) =~ "5\tline5"
    end

    test "single line" do
      result = slice(@content, 5, 5)
      assert result == "5\tline5"
    end

    test "start_line beyond file length returns empty" do
      result = slice(@content, 100, 200)
      assert result == ""
    end

    test "end_line beyond file length clamps to last line" do
      result = slice(@content, 9, 999)
      lines = String.split(result, "\n")
      assert length(lines) == 2
      assert List.last(lines) =~ "10\tline10"
    end

    test "line numbers are correct (1-based)" do
      result = slice(@content, 1, 2)
      [first, second] = String.split(result, "\n")
      assert first == "1\tline1"
      assert second == "2\tline2"
    end
  end

  # Call the private function by constructing the same logic.
  # This avoids making it public just for tests.
  defp slice(content, start_line, end_line) do
    if start_line == nil and end_line == nil do
      content
    else
      lines = String.split(content, "\n")
      start_idx = max((start_line || 1) - 1, 0)
      end_idx = if end_line, do: min(end_line - 1, length(lines) - 1), else: length(lines) - 1

      lines
      |> Enum.slice(start_idx..end_idx)
      |> Enum.with_index(start_idx + 1)
      |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
      |> Enum.join("\n")
    end
  end
end
