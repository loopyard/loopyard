defmodule Loopyard.ChatAgent.OSProcess do
  @moduledoc """
  OS-level process wrangling for a ChatAgent's harness subprocess.

  The harness session is a BEAM GenServer, but underneath it spawns an
  OS-level subprocess via `Port` — the agent CLI for the Claude SDK
  backend, or the transport Port for an ACP backend. When we need to
  hard-stop an agent, terminating the GenServer isn't enough — it
  leaves that subprocess running as an orphan. These helpers introspect
  the harness session GenServer's linked-process topology to find and
  kill the OS pid.

  Extracted from `ChatAgent` so the GenServer body isn't peppered with
  unrelated `:sys.get_state` introspection of deps internals.
  """

  @doc """
  Find the OS pid of the Claude CLI subprocess owned by an SDK session.

  Walks: SDK session GenServer → linked children → adapter process
  holding a `:port` → `Port.info(:os_pid)`. Returns `nil` if the
  session is dead, the adapter isn't linked, or the Port isn't there
  (e.g. session never fully started).

  Catches everything — it's diagnostic, so "I don't know" is a valid
  answer and must not crash the caller.
  """
  def pid_of(session) do
    {:links, links} = Process.info(session, :links)

    Enum.find_value(links, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          state = :sys.get_state(pid, 500)

          if is_map(state) and Map.has_key?(state, :port) and is_port(state.port) do
            case Port.info(state.port, :os_pid) do
              {:os_pid, os_pid} -> os_pid
              _ -> nil
            end
          end
        catch
          _, _ -> nil
        end
      end
    end)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  SIGKILL the given OS pid. Silent on any failure — the caller's goal
  is "the process is no longer running," and if `kill -9` errored then
  either it's already gone or we can't kill it and retrying won't
  help. No surface for errors here.
  """
  def kill(os_pid) do
    System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
