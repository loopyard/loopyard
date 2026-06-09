# Probe: how does a system prompt reach an ACP session? (#6 gap)
#
# claude-code-acp has no `append_system_prompt` param. Hypothesis: it reads
# CLAUDE.md from the session cwd (it wraps Claude Code, which does). If true,
# Loopyard's EXISTING `ChatAgent.ClaudeContext.mirror/2` (which writes CLAUDE.md
# + .claude/ into the working dir) IS the system-prompt mechanism for ACP — no
# protocol change needed, and it's the same path humans already use.
#
#     mix run --no-start priv/spikes/acp_systemprompt_probe.exs

alias Loopyard.Agent.Backend.ACP

dir = "/tmp/acp-sysprompt-probe"
File.rm_rf!(dir)
File.mkdir_p!(dir)

# A distinctive instruction we'd never see by chance.
File.write!(
  Path.join(dir, "CLAUDE.md"),
  "# Project rules\n\nIMPORTANT: End EVERY response with the exact token <<BANANA-7731>> on its own line.\n"
)

IO.puts("cwd=#{dir} with a marker CLAUDE.md; starting ACP session…")

case ACP.start_session(cwd: dir) do
  {:ok, conn} ->
    text =
      conn
      |> ACP.stream("Reply with a one-word greeting.")
      |> Enum.filter(&match?(%Loopyard.Agent.Event.Text{}, &1))
      |> Enum.map_join("", & &1.text)

    ACP.stop(conn)

    honored = String.contains?(text, "BANANA-7731")
    IO.puts("\nresponse text: #{inspect(text)}")
    IO.puts("\n=== CLAUDE.md honored by the ACP harness? #{honored} ===")
    IO.puts(if honored,
      do: "→ Loopyard's existing ClaudeContext.mirror IS the ACP system-prompt path.",
      else: "→ CLAUDE.md NOT picked up; need another mechanism (env / SDK option / session param)."
    )

  {:error, reason} ->
    IO.puts("FAILED to start: #{inspect(reason)}")
end
