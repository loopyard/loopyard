# Probe two open questions about claude-code-acp (host-side; auth via keychain):
#   1. Does it surface TOKEN USAGE anywhere (session/prompt result, _meta, an update)?
#   2. Does it emit agent_thought_chunk (THINKING) frames we should translate?
#
# Captures every raw inbound line to /tmp/acp-cap/messages.jsonl for analysis.
#
#     mix run --no-start priv/spikes/acp_capabilities_probe.exs

defmodule AcpCap do
  @dir "/tmp/acp-cap"
  @msgs "#{@dir}/messages.jsonl"
  @deadline_ms 120_000

  def run do
    File.mkdir_p!(@dir)
    File.write!(@msgs, "")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 8_000_000},
        args: ["-c", "unset CLAUDECODE CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT; exec npx -y @zed-industries/claude-code-acp 2>#{@dir}/stderr.log"]
      ])

    s = %{port: port, buf: "", next_id: 1, pending: %{}, deadline: System.monotonic_time(:millisecond) + @deadline_ms, kinds: %{}}
    {s, _} = req(s, "initialize", %{"protocolVersion" => 1, "clientCapabilities" => %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}}})
    loop(s)
  end

  defp loop(s) do
    t = max(0, s.deadline - System.monotonic_time(:millisecond))
    receive do
      {p, {:data, {:eol, l}}} when p == s.port -> loop(line(%{s | buf: ""}, s.buf <> l))
      {p, {:data, {:noeol, part}}} when p == s.port -> loop(%{s | buf: s.buf <> part})
      {p, {:exit_status, c}} when p == s.port -> IO.puts("[exit #{c}]"); report(s)
      _ -> loop(s)
    after
      t -> IO.puts("[deadline]"); report(s)
    end
  end

  defp line(s, l) do
    File.write!(@msgs, l <> "\n", [:append])
    case l |> String.trim() |> dec() do
      {:ok, m} -> dispatch(s, m)
      :skip -> s
    end
  end

  defp dec(""), do: :skip
  defp dec(l), do: (case Jason.decode(l), do: ({:ok, m} -> {:ok, m}; _ -> :skip))

  defp dispatch(s, %{"id" => id} = m) do
    cond do
      Map.has_key?(s.pending, id) -> {k, p} = Map.pop(s.pending, id); on_result(%{s | pending: p}, k, m)
      Map.has_key?(m, "method") -> agent_req(s, id, m["method"], m["params"] || %{})
      true -> s
    end
  end

  defp dispatch(s, %{"method" => "session/update", "params" => %{"update" => u}}) do
    kind = u["sessionUpdate"]
    s = %{s | kinds: Map.update(s.kinds, kind, 1, &(&1 + 1))}
    if kind == "agent_thought_chunk", do: IO.puts("  💭 THINKING: #{inspect(get_in(u, ["content", "text"]))}")
    s
  end

  defp dispatch(s, _), do: s

  defp on_result(s, :initialize, _), do: (elem(req(s, "session/new", %{"cwd" => File.cwd!(), "mcpServers" => []}), 0))
  defp on_result(s, :session_new, %{"result" => r}) do
    {s, _} = req(s, "session/prompt", %{"sessionId" => r["sessionId"], "prompt" => [%{"type" => "text", "text" => "Think step by step (out loud) about whether 91 is a prime number, then give a one-line final answer."}]})
    s
  end
  defp on_result(s, :session_prompt, m) do
    IO.puts("\n=== session/prompt RESULT (raw, checking for usage) ===")
    IO.inspect(m["result"] || m["error"], limit: :infinity)
    report(s)
  end
  defp on_result(s, _, _), do: s

  defp agent_req(s, id, "fs/read_text_file", p) do
    File.read(p["path"] || "") |> then(fn r -> respond(s, id, %{"content" => (case r, do: ({:ok, c} -> c; _ -> ""))}) end)
    s
  end
  defp agent_req(s, id, "session/request_permission", p) do
    opts = p["options"] || []
    pick = Enum.find(opts, &String.starts_with?(to_string(&1["kind"] || ""), "allow")) || List.first(opts)
    respond(s, id, %{"outcome" => %{"outcome" => "selected", "optionId" => pick && pick["optionId"]}}); s
  end
  defp agent_req(s, id, _, _), do: (respond(s, id, %{}); s)

  defp req(s, method, params) do
    id = s.next_id
    snd(s, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    {%{s | next_id: id + 1, pending: Map.put(s.pending, id, kind(method))}, id}
  end
  defp respond(s, id, result), do: snd(s, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  defp snd(s, m), do: Port.command(s.port, Jason.encode!(m) <> "\n")
  defp kind("initialize"), do: :initialize
  defp kind("session/new"), do: :session_new
  defp kind("session/prompt"), do: :session_prompt
  defp kind(o), do: o

  defp report(s) do
    IO.puts("\n=== update kinds: #{inspect(s.kinds)} ===")
    raw = File.read!(@msgs)
    IO.puts("raw contains 'usage'? #{String.contains?(raw, "usage")}")
    IO.puts("raw contains 'thought'? #{String.contains?(raw, "thought")}")
    IO.puts("raw contains 'tokens'? #{String.contains?(raw, "token")}")
    System.halt(0)
  end
end

AcpCap.run()
