# One synthetic heavy turn against the profiling agent. Loaded via
# Code.eval_file from Tidewave eval (modules defined in Tidewave get
# namespaced, so this is plain top-level code).
alias Loopyard.Agent.Event

id = "profagent00000001"
[{pid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, id)
ref = make_ref()
:sys.replace_state(pid, fn s -> %{s | stream_ref: ref, status: :thinking} end)

for i <- 1..20 do
  send(pid, {:stream_event, id, ref, %Event.ThinkingDelta{thinking: "considering step #{i} of the plan... "}})
  Process.sleep(10)
end

for i <- 1..30 do
  send(pid, {:stream_event, id, ref, %Event.TextDelta{text: "chunk #{i}: lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod. "}})
  Process.sleep(10)
end

code =
  Enum.map_join(1..300, "\n", fn i ->
    "   #{i}→def line_#{i}(x), do: x + #{i} # padding padding padding padding padding"
  end)

for _t <- 1..8 do
  send(pid, {:stream_event, id, ref, %Event.ToolCall{name: "Read", input: %{"file_path" => "/tmp/loopyard-prof-project/mod_#{:erlang.unique_integer([:positive])}.ex"}}})
  Process.sleep(15)
  send(pid, {:stream_event, id, ref, %Event.ToolResult{content: code, is_error: false}})
  Process.sleep(15)
end

send(pid, {:stream_event, id, ref, %Event.Text{text: String.duplicate("Final answer prose sentence with detail. ", 60)}})
send(pid, {:stream_done, id, ref})
length(:sys.get_state(pid).messages)
