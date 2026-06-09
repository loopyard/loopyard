# Probe (#7): validate the REAL permission flow. Prompt a write/exec and capture
# whether the adapter sends session/request_permission (and its option shapes)
# and/or delegates fs/write_text_file — informs the approve/deny UI (#7) and the
# in-container fs model (#5).
#
#     mix run --no-start priv/spikes/acp_permission_probe.exs

defmodule AcpPerm do
  @dir "/tmp/acp-perm"
  @deadline_ms 120_000

  def run do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary, :exit_status, {:line, 8_000_000},
        args: ["-c", "unset CLAUDECODE CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT; exec npx -y @zed-industries/claude-code-acp 2>#{@dir}/stderr.log"]
      ])

    s = %{port: port, buf: "", next_id: 1, pending: %{}, perms: [], writes: [], deadline: System.monotonic_time(:millisecond) + @deadline_ms}
    {s, _} = req(s, "initialize", %{"protocolVersion" => 1, "clientCapabilities" => %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}}})
    loop(s)
  end

  defp loop(s) do
    t = max(0, s.deadline - System.monotonic_time(:millisecond))
    receive do
      {p, {:data, {:eol, l}}} when p == s.port -> loop(line(%{s | buf: ""}, s.buf <> l))
      {p, {:data, {:noeol, x}}} when p == s.port -> loop(%{s | buf: s.buf <> x})
      {p, {:exit_status, c}} when p == s.port -> IO.puts("[exit #{c}]"); report(s)
      _ -> loop(s)
    after t -> IO.puts("[deadline]"); report(s) end
  end

  defp line(s, l), do: (case l |> String.trim() |> dec() do
    {:ok, m} -> dispatch(s, m)
    :skip -> s
  end)
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
    if u["sessionUpdate"] == "tool_call", do: IO.puts("  tool_call: #{inspect(get_in(u, ["_meta","claudeCode","toolName"]))} #{inspect(u["rawInput"])}")
    s
  end
  defp dispatch(s, _), do: s

  defp on_result(s, :initialize, _), do: elem(req(s, "session/new", %{"cwd" => @dir, "mcpServers" => []}), 0)
  defp on_result(s, :session_new, %{"result" => r}) do
    {s, _} = req(s, "session/prompt", %{"sessionId" => r["sessionId"], "prompt" => [%{"type" => "text", "text" => "Create a file called hello.txt containing the text 'hi from loopyard'. Then run the shell command 'echo done'."}]})
    s
  end
  defp on_result(s, :session_prompt, m), do: (IO.puts("  prompt done: #{inspect(m["result"] || m["error"])}"); report(s))
  defp on_result(s, _, _), do: s

  defp agent_req(s, id, "session/request_permission", p) do
    opts = p["options"] || []
    tool = get_in(p, ["toolCall", "title"]) || get_in(p, ["toolCall", "rawInput"])
    IO.puts("  ⮕ request_permission for #{inspect(tool)} options=#{inspect(Enum.map(opts, &{&1["optionId"], &1["kind"]}))}")
    pick = Enum.find(opts, &String.starts_with?(to_string(&1["kind"] || ""), "allow")) || List.first(opts)
    respond(s, id, %{"outcome" => %{"outcome" => "selected", "optionId" => pick && pick["optionId"]}})
    %{s | perms: [tool | s.perms]}
  end
  defp agent_req(s, id, "fs/write_text_file", p) do
    IO.puts("  ⮕ fs/write_text_file #{p["path"]} (client writes)")
    File.write(p["path"] || "", p["content"] || "")
    respond(s, id, %{})
    %{s | writes: [p["path"] | s.writes]}
  end
  defp agent_req(s, id, "fs/read_text_file", p) do
    respond(s, id, %{"content" => (case File.read(p["path"] || ""), do: ({:ok, c} -> c; _ -> ""))}); s
  end
  defp agent_req(s, id, _m, _p), do: (respond(s, id, %{}); s)

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
    IO.puts("\n=== PERMISSION FLOW ===")
    IO.puts("request_permission count: #{length(s.perms)}")
    IO.puts("fs/write_text_file count: #{length(s.writes)}")
    IO.puts("hello.txt created? #{File.exists?(Path.join(@dir, "hello.txt"))}")
    System.halt(0)
  end
end

AcpPerm.run()
