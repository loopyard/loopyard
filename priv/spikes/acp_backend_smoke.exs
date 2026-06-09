# End-to-end smoke of Backend.ACP against the REAL adapter (not the fake).
# Proves the whole vertical: start_session -> stream -> translated
# Loopyard.Agent.Event structs, driving the real claude-code-acp harness.
#
#     mix run --no-start priv/spikes/acp_backend_smoke.exs

alias Loopyard.Agent.Backend.ACP

IO.puts("starting ACP session against the real adapter…")

case ACP.start_session(cwd: File.cwd!()) do
  {:ok, conn} ->
    IO.puts("ready. session_id=#{inspect(ACP.session_id(conn))} alive=#{ACP.session_alive?(conn)}")

    events =
      conn
      |> ACP.stream("Reply with exactly the word: pong. Do not use any tools.")
      |> Enum.to_list()

    IO.puts("\n--- #{length(events)} translated events ---")
    Enum.each(events, &IO.inspect(&1, label: "event"))

    text =
      events
      |> Enum.filter(&match?(%Loopyard.Agent.Event.Text{}, &1))
      |> Enum.map_join("", & &1.text)

    IO.puts("\nfinal committed text: #{inspect(text)}")
    ACP.stop(conn)
    IO.puts("stopped. PASS=#{String.contains?(String.downcase(text), "pong")}")

  {:error, reason} ->
    IO.puts("FAILED to start: #{inspect(reason)}")
end
