# In-container ACP spike (#5). Drives the adapter INSIDE a Docker container via
# `docker exec -i`, and declares NO client fs capability — testing whether the
# adapter then reads the CONTAINER's own filesystem natively (Option A) instead
# of delegating fs/read_text_file back to the host (Option B).
#
# Prereq: the `loopyard-acp-incontainer-test` container from the setup step
# (node + claude-code-acp + /workspace/mix.exs with app: :incontainer_demo).
#
#     mix run --no-start priv/spikes/acp_incontainer_smoke.exs

defmodule AcpInContainer do
  @container "loopyard-acp-incontainer-test"
  @log_dir "/tmp/acp-incontainer"
  @deadline_ms 120_000

  def run do
    File.mkdir_p!(@log_dir)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 8_000_000},
        args: ["-c", "exec docker exec -i #{@container} claude-code-acp 2>#{@log_dir}/stderr.log"]
      ])

    state = %{
      port: port,
      buf: "",
      next_id: 1,
      pending: %{},
      fs_delegated: false,
      deadline: System.monotonic_time(:millisecond) + @deadline_ms
    }

    # initialize WITHOUT fs capability — force the adapter to use its own tools.
    {state, _} =
      request(state, "initialize", %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{}
      })

    loop(state)
  end

  defp loop(state) do
    timeout = max(0, state.deadline - System.monotonic_time(:millisecond))

    receive do
      {p, {:data, {:eol, line}}} when p == state.port ->
        loop(handle_line(%{state | buf: ""}, state.buf <> line))

      {p, {:data, {:noeol, part}}} when p == state.port ->
        loop(%{state | buf: state.buf <> part})

      {p, {:exit_status, code}} when p == state.port ->
        IO.puts("[adapter exited #{code}]")
        report(state)

      _ ->
        loop(state)
    after
      timeout ->
        IO.puts("[deadline]")
        report(state)
    end
  end

  defp handle_line(state, line) do
    case line |> String.trim() |> decode() do
      {:ok, msg} -> dispatch(state, msg)
      :skip -> state
    end
  end

  defp decode(""), do: :skip
  defp decode(l), do: (case Jason.decode(l), do: ({:ok, m} -> {:ok, m}; _ -> :skip))

  defp dispatch(state, %{"id" => id} = msg) do
    cond do
      Map.has_key?(state.pending, id) ->
        {kind, pending} = Map.pop(state.pending, id)
        on_result(%{state | pending: pending}, kind, msg)

      Map.has_key?(msg, "method") ->
        agent_request(state, id, msg["method"], msg["params"] || %{})

      true ->
        state
    end
  end

  defp dispatch(state, %{"method" => "session/update", "params" => %{"update" => u}}) do
    kind = u["sessionUpdate"]
    text = get_in(u, ["content", "text"])
    IO.puts("  ◦ #{kind}#{if text, do: ": " <> inspect(text), else: ""}")
    if kind == "tool_call", do: IO.puts("    tool: #{inspect(get_in(u, ["_meta", "claudeCode", "toolName"]))} raw=#{inspect(u["rawInput"])}")
    state
  end

  defp dispatch(state, _), do: state

  defp on_result(state, :initialize, _msg) do
    IO.puts("← initialize ok")
    {state, _} = request(state, "session/new", %{"cwd" => "/workspace", "mcpServers" => []})
    state
  end

  defp on_result(state, :session_new, %{"result" => r}) do
    IO.puts("← session/new ok, sessionId=#{r["sessionId"]}")
    {state, _} =
      request(state, "session/prompt", %{
        "sessionId" => r["sessionId"],
        "prompt" => [%{"type" => "text", "text" => "Read the file mix.exs in the current directory and tell me the :app atom and the version. Be brief."}]
      })
    state
  end

  defp on_result(state, :session_new, %{"error" => e}) do
    IO.puts("← session/new ERROR: #{inspect(e)}")
    report(state)
  end

  defp on_result(state, :session_prompt, msg) do
    IO.puts("← session/prompt done: #{inspect(msg["result"] || msg["error"])}")
    report(state)
  end

  defp on_result(state, _k, _m), do: state

  # The critical observation: if this fires, the in-container adapter delegated
  # fs back to the host (Option B) — and the host can't see /workspace.
  defp agent_request(state, id, "fs/read_text_file", params) do
    IO.puts("  ⚠ fs/read_text_file DELEGATED TO HOST for #{params["path"]} (Option B!)")
    host_read = File.read(params["path"] || "")
    respond(state, id, %{"content" => (case host_read, do: ({:ok, c} -> c; _ -> "HOST-CANNOT-READ"))})
    %{state | fs_delegated: true}
  end

  defp agent_request(state, id, "session/request_permission", params) do
    opts = params["options"] || []
    pick = Enum.find(opts, &String.starts_with?(to_string(&1["kind"] || ""), "allow")) || List.first(opts)
    IO.puts("  permission → #{inspect(pick && pick["optionId"])}")
    respond(state, id, %{"outcome" => %{"outcome" => "selected", "optionId" => pick && pick["optionId"]}})
    state
  end

  defp agent_request(state, id, method, _p) do
    IO.puts("  agent request #{method} → empty")
    respond(state, id, %{})
    state
  end

  defp request(state, method, params) do
    id = state.next_id
    send_msg(state, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    {%{state | next_id: id + 1, pending: Map.put(state.pending, id, kind(method))}, id}
  end

  defp respond(state, id, result), do: send_msg(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp send_msg(state, msg), do: Port.command(state.port, Jason.encode!(msg) <> "\n")

  defp kind("initialize"), do: :initialize
  defp kind("session/new"), do: :session_new
  defp kind("session/prompt"), do: :session_prompt
  defp kind(o), do: o

  defp report(state) do
    IO.puts("\n================ IN-CONTAINER VERDICT ================")
    IO.puts("fs delegated to host (Option B)?  #{state.fs_delegated}")
    IO.puts("If false and the model named :incontainer_demo, the adapter read")
    IO.puts("the CONTAINER filesystem natively (Option A) — the clean model.")
    IO.puts("Adapter stderr: #{@log_dir}/stderr.log")
    System.halt(0)
  end
end

AcpInContainer.run()
