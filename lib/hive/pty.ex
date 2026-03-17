defmodule Hive.PTY do
  @moduledoc """
  Cross-platform PTY allocation using the `script` command.
  macOS and Linux have different `script` syntax.
  """

  @doc """
  Returns the `script` executable path and args needed to wrap a command in a PTY.

  macOS:  script -q /dev/null <cmd>
  Linux:  script -qc <cmd> /dev/null
  """
  @spec wrap_command(String.t()) :: {String.t(), [String.t()]}
  def wrap_command(cmd) do
    script_path = System.find_executable("script") || raise "script not found in PATH"

    case os_type() do
      :macos ->
        {script_path, ["-q", "/dev/null", cmd]}

      :linux ->
        {script_path, ["-qc", cmd, "/dev/null"]}
    end
  end

  @doc """
  Returns the env vars to set terminal size for the PTY.
  """
  @spec terminal_env(pos_integer(), pos_integer()) :: [{charlist(), charlist()}]
  def terminal_env(cols, rows) do
    [
      {~c"TERM", ~c"xterm-256color"},
      {~c"COLUMNS", ~c"#{cols}"},
      {~c"LINES", ~c"#{rows}"}
    ]
  end

  @doc """
  Detects the current OS type.
  """
  @spec os_type() :: :macos | :linux
  def os_type do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
    end
  end
end
