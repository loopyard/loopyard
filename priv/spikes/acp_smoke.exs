# ACP-in-harness spike (Epic #3 / #4).
#
# Goal: prove Elixir can drive the real `@zed-industries/claude-code-acp`
# adapter over stdio JSON-RPC, and capture the actual `session/update`
# event shapes we need to translate into Loopyard.Agent.Event structs.
#
# Run host-side (uses your existing Claude login — no container, no
# credential-in-container decision):
#
#     mix run --no-start priv/spikes/acp_smoke.exs
#
# Logs every raw protocol message to /tmp/acp/messages.jsonl and prints a
# readable trace. Adapter stderr goes to /tmp/acp/stderr.log.

defmodule AcpSmoke do
  @log_dir "/tmp/acp"
  @messages "#{@log_dir}/messages.jsonl"
  @deadline_ms 120_000

  def run do
    File.mkdir_p!(@log_dir)
    File.write!(@messages, "")

    port =
      Port.open({:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          {:line, 4_000_000},
          # Unset CLAUDECODE so the adapter doesn't think it's a nested
          # Claude Code session and refuse to launch.
          args: ["-c", "unset CLAUDECODE CLAUDE_CODE_SSE_PORT CLAUDE_CODE_ENTRYPOINT; exec npx -y @zed-industries/claude-code-acp 2>#{@log_dir}/stderr.log"]
        ]
      )

    state = %{
      port: port,
      buf: "",
      next_id: 1,
      pending: %{},
      session_id: nil,
      phase: :init,
      deadline: System.monotonic_time(:millisecond) + @deadline_ms
    }

    # Kick off: initialize
    {state, _id} =
      request(state, "initialize", %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{
          "fs" => %{"readTextFile" => true, "writeTextFile" => true}
        }
      })

    loop(state)
  end

  # ---- main receive loop ----

  defp loop(state) do
    timeout = max(0, state.deadline - System.monotonic_time(:millisecond))

    receive do
      {port, {:data, {:eol, line}}} when port == state.port ->
        state = %{state | buf: state.buf <> line}
        state = handle_line(state, state.buf)
        loop(%{state | buf: ""})

      {port, {:data, {:noeol, part}}} when port == state.port ->
        loop(%{state | buf: state.buf <> part})

      {port, {:exit_status, code}} when port == state.port ->
        IO.puts("\n[adapter exited: #{code}]")
        report()

      other ->
        IO.inspect(other, label: "unexpected")
        loop(state)
    after
      timeout ->
        IO.puts("\n[deadline reached]")
        catch_close(state.port)
        report()
    end
  end

  defp handle_line(state, line) do
    line = String.trim(line)
    if line == "" do
      state
    else
      log(line, :in)

      case Jason.decode(line) do
        {:ok, msg} -> dispatch(state, msg)
        {:error, _} ->
          IO.puts("  (non-JSON line)")
          state
      end
    end
  end

  # ---- dispatch incoming JSON-RPC ----

  # Response to one of our requests
  defp dispatch(state, %{"id" => id, "result" => result}) when is_map_key(state.pending, id) do
    {method, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}
    IO.puts("← result for #{method}: #{summ(result)}")
    on_result(state, method, result)
  end

  defp dispatch(state, %{"id" => id, "error" => error}) when is_map_key(state.pending, id) do
    {method, pending} = Map.pop(state.pending, id)
    IO.puts("← ERROR for #{method}: #{inspect(error)}")
    %{state | pending: pending}
  end

  # Incoming request FROM the agent (has id + method) — must respond
  defp dispatch(state, %{"id" => id, "method" => method} = msg) do
    IO.puts("→ agent request: #{method}")
    handle_agent_request(state, id, method, msg["params"] || %{})
  end

  # Notification (method, no id)
  defp dispatch(state, %{"method" => method} = msg) do
    handle_notification(state, method, msg["params"] || %{})
    state
  end

  defp dispatch(state, other) do
    IO.inspect(other, label: "unhandled message")
    state
  end

  # ---- handle our request results: drive the handshake forward ----

  defp on_result(state, "initialize", result) do
    IO.puts("  agent protocolVersion=#{inspect(result["protocolVersion"])} authMethods=#{inspect(result["authMethods"])}")
    {state, _} =
      request(state, "session/new", %{
        "cwd" => File.cwd!(),
        "mcpServers" => []
      })
    state
  end

  defp on_result(state, "session/new", result) do
    sid = result["sessionId"]
    IO.puts("  sessionId=#{sid}")
    state = %{state | session_id: sid}

    {state, _} =
      request(state, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [
          %{"type" => "text", "text" => "In one short sentence, say hello and tell me what directory you are in. Then read the file mix.exs and tell me the project's :app name. Keep it brief."}
        ]
      })

    state
  end

  defp on_result(state, "session/prompt", result) do
    IO.puts("  prompt finished, stopReason=#{inspect(result["stopReason"])}")
    catch_close(state.port)
    report()
    # report() halts
    state
  end

  defp on_result(state, _method, _result), do: state

  # ---- handle agent-initiated requests ----

  defp handle_agent_request(state, id, "session/request_permission", params) do
    options = params["options"] || []
    pick =
      Enum.find(options, fn o -> String.starts_with?(to_string(o["kind"] || ""), "allow") end) ||
        List.first(options)

    IO.puts("  permission for tool: #{summ(params["toolCall"])} → choosing #{inspect(pick && pick["optionId"])}")

    respond(state, id, %{
      "outcome" => %{"outcome" => "selected", "optionId" => pick && pick["optionId"]}
    })
  end

  defp handle_agent_request(state, id, "fs/read_text_file", params) do
    path = params["path"]
    content =
      case File.read(path) do
        {:ok, data} -> data
        {:error, reason} -> "ERROR reading #{path}: #{inspect(reason)}"
      end

    IO.puts("  fs/read_text_file #{path} (#{byte_size(content)} bytes)")
    respond(state, id, %{"content" => content})
  end

  defp handle_agent_request(state, id, "fs/write_text_file", params) do
    IO.puts("  fs/write_text_file #{params["path"]} (NOT writing in spike — acking)")
    respond(state, id, %{})
  end

  defp handle_agent_request(state, id, method, _params) do
    IO.puts("  unknown agent request #{method} — responding empty")
    respond(state, id, %{})
  end

  # ---- notifications ----

  defp handle_notification(_state, "session/update", params) do
    update = params["update"] || %{}
    kind = update["sessionUpdate"]
    IO.puts("  ◦ update[#{kind}]: #{summ(update)}")
  end

  defp handle_notification(_state, method, params) do
    IO.puts("  ◦ notification #{method}: #{summ(params)}")
  end

  # ---- jsonrpc plumbing ----

  defp request(state, method, params) do
    id = state.next_id
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    send_msg(state.port, msg)
    {%{state | next_id: id + 1, pending: Map.put(state.pending, id, method)}, id}
  end

  defp respond(state, id, result) do
    send_msg(state.port, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    state
  end

  defp send_msg(port, msg) do
    line = Jason.encode!(msg)
    log(line, :out)
    IO.puts("→ #{msg["method"] || "response"} #{(msg["id"] && "##{msg["id"]}") || ""}")
    Port.command(port, line <> "\n")
  end

  defp catch_close(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  # ---- logging / reporting ----

  defp log(line, dir) do
    tag = if dir == :in, do: "<<", else: ">>"
    File.write!(@messages, "#{tag} #{line}\n", [:append])
  end

  defp summ(nil), do: "nil"
  defp summ(map) when is_map(map) do
    s = inspect(map, limit: :infinity, printable_limit: 400)
    if String.length(s) > 400, do: String.slice(s, 0, 400) <> "…", else: s
  end
  defp summ(other), do: inspect(other)

  defp report do
    IO.puts("\n================ SHAPE REPORT ================")
    IO.puts("Raw transcript: #{@messages}")
    IO.puts("Adapter stderr: #{@log_dir}/stderr.log\n")

    case File.read(@messages) do
      {:ok, body} ->
        kinds =
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn l ->
            case Regex.run(~r/"sessionUpdate":"([^"]+)"/, l) do
              [_, k] -> [k]
              _ -> []
            end
          end)
          |> Enum.frequencies()

        IO.puts("session/update kinds observed: #{inspect(kinds)}")

      _ ->
        :ok
    end

    System.halt(0)
  end
end

AcpSmoke.run()
