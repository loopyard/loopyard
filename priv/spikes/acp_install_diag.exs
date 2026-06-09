# Diagnostic (#6): which install target reliably reaches the harness?
# Tests 4 variants with an identical instruction, non-conflicting prompt.
#
#     mix run --no-start priv/spikes/acp_install_diag.exs

alias Loopyard.Agent.Backend.ACP

instr = "IMPORTANT: include the token <<TOK>> somewhere in your reply."
managed = "<!-- BEGIN LOOPYARD AGENT (managed) -->\n\n" <> instr <> "\n\n<!-- END LOOPYARD AGENT -->\n"

run = fn label, setup ->
  dir = "/tmp/acp-diag-#{label}"
  File.rm_rf!(dir)
  File.mkdir_p!(dir)
  setup.(dir)

  case ACP.start_session(cwd: dir) do
    {:ok, conn} ->
      text =
        conn
        |> ACP.stream("Reply with a brief friendly greeting.")
        |> Enum.filter(&match?(%Loopyard.Agent.Event.Text{}, &1))
        |> Enum.map_join("", & &1.text)

      ACP.stop(conn)
      IO.puts("#{label}: token? #{String.contains?(text, "<<TOK>>")}  resp=#{inspect(text)}")

    {:error, r} ->
      IO.puts("#{label}: start error #{inspect(r)}")
  end
end

run.("v1_local_managed", fn dir -> File.write!(Path.join(dir, "CLAUDE.local.md"), managed) end)
run.("v2_local_managed_plus_md", fn dir ->
  File.write!(Path.join(dir, "CLAUDE.md"), "# Project\n")
  File.write!(Path.join(dir, "CLAUDE.local.md"), managed)
end)
run.("v3_local_plain", fn dir -> File.write!(Path.join(dir, "CLAUDE.local.md"), instr <> "\n") end)
run.("v4_md_managed", fn dir -> File.write!(Path.join(dir, "CLAUDE.md"), managed) end)
