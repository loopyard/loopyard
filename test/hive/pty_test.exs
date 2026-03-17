defmodule Hive.PTYTest do
  use ExUnit.Case, async: true

  alias Hive.PTY

  describe "wrap_command/1" do
    test "returns script path and args for the current OS" do
      {script_path, args} = PTY.wrap_command("/usr/bin/echo")

      assert is_binary(script_path)
      assert String.ends_with?(script_path, "script")

      case PTY.os_type() do
        :macos ->
          assert args == ["-q", "/dev/null", "/usr/bin/echo"]

        :linux ->
          assert args == ["-qc", "/usr/bin/echo", "/dev/null"]
      end
    end
  end

  describe "terminal_env/2" do
    test "returns correct env var tuples" do
      env = PTY.terminal_env(120, 40)

      assert {~c"TERM", ~c"xterm-256color"} in env
      assert {~c"COLUMNS", ~c"120"} in env
      assert {~c"LINES", ~c"40"} in env
    end

    test "works with custom dimensions" do
      env = PTY.terminal_env(200, 50)

      assert {~c"COLUMNS", ~c"200"} in env
      assert {~c"LINES", ~c"50"} in env
    end
  end

  describe "os_type/0" do
    test "returns :macos or :linux" do
      assert PTY.os_type() in [:macos, :linux]
    end
  end
end
