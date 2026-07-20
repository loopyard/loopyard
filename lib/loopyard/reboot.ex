defmodule Loopyard.Reboot do
  @moduledoc """
  Full-VM reboot of the Loopyard server: kill THIS BEAM's OS process and
  relaunch a fresh `mix loopyard.server`. Backs the /system reboot button.

  ## Why kill+relaunch, not `Application.stop/start` in place

  An in-place application restart is fundamentally unreliable as a "reboot":
  it races on ETS ownership (`StateKeeper`'s tables) and logger handlers, it
  depends on every `terminate/2` + boot-recovery step being idempotent, and —
  the killer — **if `start/2` raises mid-recovery the app stays down with the
  VM still alive**. You cannot dependably tear the phx app down and rebuild it
  from *inside* that same app. A fresh OS process gives a clean VM every time.
  Docker containers persist across it; boot recovery reconnects to them.

  ## How the detach works

  The relauncher runs as a shell that is `nohup`'d, has its stdio redirected to
  the server log, and is backgrounded so its launching shell exits immediately —
  which reparents it to launchd/init. That's what lets it survive the BEAM it is
  about to kill. It waits for the HTTP port to actually free before relaunching,
  so the new VM never races the old one for `:4000`.
  """
  require Logger

  @log "/tmp/loopyard-server.log"

  @doc """
  Kick off a full-VM reboot. Returns `:ok` once the detached helper is launched
  (the current VM dies ~1s later); `{:error, reason}` if the helper couldn't be
  written/launched.
  """
  @spec trigger() :: :ok | {:error, term()}
  def trigger do
    os_pid = System.pid()
    dir = File.cwd!()
    mix = System.find_executable("mix") || "mix"
    script = script_path()

    body = """
    #!/bin/sh
    # Loopyard reboot helper — DETACHED, so it outlives the BEAM (#{os_pid}) it
    # kills below. Do not run directly; written + launched by Loopyard.Reboot.
    sleep 1
    kill #{os_pid} 2>/dev/null
    pkill -f 'mix loopyard.server' 2>/dev/null   # belt + suspenders
    # Wait (up to 30s) for the HTTP port to free so the fresh VM won't race it.
    i=0
    while lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1 && [ "$i" -lt 30 ]; do
      sleep 1
      i=$((i + 1))
    done
    cd '#{dir}' || exit 1
    exec nohup '#{mix}' loopyard.server >> '#{@log}' 2>&1 < /dev/null
    """

    with :ok <- File.write(script, body),
         :ok <- File.chmod(script, 0o755) do
      # `nohup … &` then let the launching shell exit → the helper detaches from
      # this BEAM. System.cmd returns as soon as that outer shell backgrounds it.
      _ = System.cmd("sh", ["-c", "nohup sh '#{script}' < /dev/null >> '#{@log}' 2>&1 &"])
      Logger.warning("[Reboot] full-VM restart triggered — killing pid #{os_pid}")
      :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp script_path, do: Path.join(System.tmp_dir!(), "loopyard-reboot.sh")
end
