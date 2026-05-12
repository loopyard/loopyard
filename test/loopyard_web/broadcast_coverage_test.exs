defmodule LoopyardWeb.BroadcastCoverageTest do
  @moduledoc """
  Regression guard for the class of bug where a LiveView subscribes
  to a PubSub topic but silently drops a broadcast on that topic —
  the message falls through to `handle_info(_msg, state), do:
  {:noreply, state}` with no warning, so the UI stays stuck at its
  last-known state.

  The real-world case: ChatAgent broadcasts `:chat_agent_resumed` on
  the `"chat_agents"` topic when a supervisor restarts a crashed
  agent. The main workspace LV subscribed to the topic but had no
  matching handler clause. A user would see the sidebar pinned at
  `:crashed` while the new GenServer was already alive and idle.

  After Move #2+#3 (publisher modules + subscriber behaviours) landed,
  the primary contract is the `@behaviour` declaration — missing
  callbacks surface as compile warnings via `@impl`. This test stays
  in place as belt-and-suspenders: it verifies each LV has an
  explicit `handle_info(%Struct{} = _, socket)` dispatch clause for
  every event struct on the topics it subscribes to, so a subscriber
  that accidentally drops a struct into the catch-all (`_msg`) fails
  the test instead of silently losing broadcasts.

  For anything still broadcast as a tuple (pre-migration fallback),
  the original atom-based check still runs below.
  """

  use ExUnit.Case, async: true

  alias Loopyard.Events

  # For each LiveView, list the event modules it MUST handle. The set
  # is derived from the publisher modules — if a new event struct is
  # added to a topic a LV subscribes to, add it here and wire the
  # handler clause + behaviour callback.
  @workspace_live_required_structs Events.ChatAgent.events() ++
                                     Events.ChatAgentMessage.events() ++
                                     Events.DockerObserver.events() ++
                                     Events.WorkspaceServices.events() ++
                                     Events.SourceSync.events()

  @project_live_required_structs Events.ChatAgent.events() ++
                                   Events.WorkspaceServices.events()

  @system_docker_live_required_structs Events.DockerObserver.events()

  # SystemQuarantineLive subscribes to "chat_agents" and — per Move #3
  # — declares the behaviour, which forces it to acknowledge every
  # event. Non-quarantine callbacks no-op explicitly; the dispatcher
  # clauses still have to exist so a new event can't slip past into
  # the catch-all.
  @system_quarantine_live_required_structs Events.ChatAgent.events()

  test "workspace_live handles every event struct on topics it subscribes to" do
    assert_struct_handlers_exist(
      "lib/loopyard_web/live/workspace_live.ex",
      @workspace_live_required_structs
    )
  end

  test "project_live handles every event struct on topics it subscribes to" do
    assert_struct_handlers_exist(
      "lib/loopyard_web/live/project_live.ex",
      @project_live_required_structs
    )
  end

  test "system_docker_live handles every docker-observer event struct" do
    assert_struct_handlers_exist(
      "lib/loopyard_web/live/system_docker_live.ex",
      @system_docker_live_required_structs
    )
  end

  test "system_quarantine_live acknowledges every chat_agents event struct" do
    assert_struct_handlers_exist(
      "lib/loopyard_web/live/system_quarantine_live.ex",
      @system_quarantine_live_required_structs
    )
  end

  # ── Struct-based coverage ──

  defp assert_struct_handlers_exist(relative_path, required_modules) do
    source = File.read!(Path.join(File.cwd!(), relative_path))
    {:ok, ast} = Code.string_to_quoted(source)

    handled = collect_handled_structs(ast) |> MapSet.new()
    required = required_modules |> MapSet.new()
    missing = MapSet.difference(required, handled)

    assert MapSet.size(missing) == 0,
           "#{relative_path} subscribes to topics that publish these event structs, " <>
             "but has no matching handle_info clause: #{inspect(MapSet.to_list(missing))}. " <>
             "Add a `def handle_info(%<Struct>{} = e, socket), do: on_...(e, socket)` " <>
             "clause (the behaviour already forces the callback)."
  end

  # Walk the AST and pull every struct module referenced from a
  # handle_info pattern.
  #
  # Struct literal AST shape: `{:%, _, [{:__aliases__, _, parts}, _]}`.
  # We rebuild the module from the aliases and canonicalize it against
  # the list of published modules — unrecognized aliases are ignored
  # so local structs and third-party structs don't pollute coverage.
  defp collect_handled_structs(ast) do
    known = MapSet.new(all_event_modules())

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:handle_info, _, [pattern | _]} | _]} = node, acc ->
          {node, acc ++ structs_from_pattern(pattern, known)}

        {:def, _, [{:when, _, [{:handle_info, _, [pattern | _]}, _guard]} | _]} = node, acc ->
          {node, acc ++ structs_from_pattern(pattern, known)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp structs_from_pattern(pattern, known) do
    {_, acc} =
      Macro.prewalk(pattern, [], fn
        {:%, _, [{:__aliases__, _, parts}, _]} = node, acc ->
          # Try resolving with and without the Loopyard/Events prefix
          # so both `%Events.ChatAgent.Resumed{}` (via alias) and
          # `%Loopyard.Events.ChatAgent.Resumed{}` (fully qualified)
          # work. We canonicalize by searching `known` for a module
          # whose split-parts END with `parts`.
          {node, acc ++ resolve_struct(parts, known)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp resolve_struct(parts, known) do
    target = Enum.map(parts, &to_string/1)
    target_len = length(target)

    known
    |> Enum.filter(fn m ->
      m_parts = Module.split(m)
      m_len = length(m_parts)

      m_len >= target_len and Enum.slice(m_parts, m_len - target_len, target_len) == target
    end)
  end

  defp all_event_modules do
    Events.ChatAgent.events() ++
      Events.ChatAgentMessage.events() ++
      Events.DockerObserver.events() ++
      Events.WorkspaceServices.events() ++
      Events.SourceSync.events() ++
      Events.Terminal.events() ++
      [Events.IexSession.Changed]
  end
end
