# E2E (#6): Backend.ACP.start_session(system_prompt:) → installs CLAUDE.local.md
# → the REAL adapter reads and obeys it. Proves the whole increment.
#
#     mix run --no-start priv/spikes/acp_sysprompt_e2e.exs

alias Loopyard.Agent.Backend.ACP

dir = "/tmp/acp-sysprompt-e2e"
File.rm_rf!(dir)
File.mkdir_p!(dir)

case ACP.start_session(cwd: dir, system_prompt: "Always begin every reply with the exact word BANANA in all caps, then a newline.") do
  {:ok, conn} ->
    installed = File.exists?(Path.join(dir, "CLAUDE.local.md"))

    text =
      conn
      |> ACP.stream("Reply with a friendly sentence or two.")
      |> Enum.filter(&match?(%Loopyard.Agent.Event.Text{}, &1))
      |> Enum.map_join("", & &1.text)

    ACP.stop(conn)

    obeyed = String.contains?(String.upcase(text), "BANANA")
    IO.puts("CLAUDE.local.md installed? #{installed}")
    IO.puts("response: #{inspect(text)}")
    IO.puts("\n=== full path works (installed + harness obeyed)? #{installed and obeyed} ===")

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end
