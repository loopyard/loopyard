# Probe (#6): can Loopyard install its agent system prompt via CLAUDE.local.md
# ALONGSIDE the project's own CLAUDE.md, with the harness honoring BOTH?
# If yes, Loopyard writes its prompt to CLAUDE.local.md and never clobbers the
# project's CLAUDE.md (mirrored by ClaudeContext).
#
#     mix run --no-start priv/spikes/acp_localmd_probe.exs

alias Loopyard.Agent.Backend.ACP

dir = "/tmp/acp-localmd-probe"
File.rm_rf!(dir)
File.mkdir_p!(dir)

# The PROJECT's own file (what ClaudeContext.mirror would place).
File.write!(Path.join(dir, "CLAUDE.md"), "IMPORTANT: include the token <<PROJECT-A>> somewhere in every reply.\n")
# LOOPYARD's agent instructions (what we'd install separately).
File.write!(Path.join(dir, "CLAUDE.local.md"), "IMPORTANT: include the token <<LOOPYARD-B>> somewhere in every reply.\n")

IO.puts("cwd=#{dir} with CLAUDE.md (project) + CLAUDE.local.md (loopyard); starting…")

case ACP.start_session(cwd: dir) do
  {:ok, conn} ->
    text =
      conn
      |> ACP.stream("Say a one-word greeting.")
      |> Enum.filter(&match?(%Loopyard.Agent.Event.Text{}, &1))
      |> Enum.map_join("", & &1.text)

    ACP.stop(conn)

    project = String.contains?(text, "<<PROJECT-A>>")
    loopyard = String.contains?(text, "<<LOOPYARD-B>>")
    IO.puts("\nresponse: #{inspect(text)}")
    IO.puts("project CLAUDE.md honored?   #{project}")
    IO.puts("loopyard CLAUDE.local.md honored? #{loopyard}")

    cond do
      project and loopyard -> IO.puts("\n✅ BOTH honored — install Loopyard's prompt via CLAUDE.local.md, project CLAUDE.md untouched.")
      loopyard and not project -> IO.puts("\n⚠ only CLAUDE.local.md read — would clobber project context; use a different strategy.")
      project and not loopyard -> IO.puts("\n⚠ CLAUDE.local.md NOT read — need another install location (.claude/ or @import).")
      true -> IO.puts("\n⚠ neither read — unexpected.")
    end

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end
