defmodule BoomLooperWeb.BroadcastCoverageTest do
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

  This test asserts — statically, by parsing source files — that
  each LV we care about has an explicit `handle_info` clause for
  every event tag broadcast on topics it subscribes to. When a new
  event tag is added, this test fails in every LV that subscribes,
  forcing the author to either wire the handler or justify the drop.
  """

  use ExUnit.Case, async: true

  # For each LiveView, list the event tags it MUST handle. The tags
  # here come from the grep audit — if you add a new broadcast tag
  # on a topic a LV subscribes to, add it here and wire the handler.
  @workspace_live_required_events [
    # "chat_agents" topic
    :chat_agent_started,
    :chat_agent_stopped,
    :chat_agent_booting,
    :chat_agent_boot_status,
    :chat_agent_boot_failed,
    :chat_agent_removed,
    :chat_agent_renamed,
    :chat_agent_resumed,
    :chat_agent_status_changed,
    # "chat_agent:{id}" topic
    :chat_message,
    :chat_text_delta,
    # "docker_observer" topic
    :docker_state_changed,
    :docker_state_reset,
    :docker_state_disconnected,
    :docker_state_reconnected,
    # workspace/service events
    :compose_result
  ]

  @project_live_required_events [
    :chat_agent_started,
    :chat_agent_stopped,
    :chat_agent_booting,
    :chat_agent_removed,
    :chat_agent_resumed,
    :chat_agent_renamed,
    :chat_agent_boot_status,
    :chat_agent_boot_failed,
    :chat_agent_status_changed,
    :services_updated
  ]

  @system_docker_live_required_events [
    :docker_state_changed,
    :docker_state_reset,
    :docker_state_disconnected,
    :docker_state_reconnected
  ]

  test "workspace_live handles every event it subscribes to" do
    assert_handlers_exist(
      "lib/boom_looper_web/live/workspace_live.ex",
      @workspace_live_required_events
    )
  end

  test "project_live handles every agent-lifecycle event" do
    assert_handlers_exist(
      "lib/boom_looper_web/live/project_live.ex",
      @project_live_required_events
    )
  end

  test "system_docker_live handles every docker-observer event" do
    assert_handlers_exist(
      "lib/boom_looper_web/live/system_docker_live.ex",
      @system_docker_live_required_events
    )
  end

  # Parse the module's AST and find every `handle_info` clause's first
  # argument. If the first argument is a tuple whose head is an atom,
  # that atom is a handled event tag. Compare against the required set.
  defp assert_handlers_exist(relative_path, required_tags) do
    source = File.read!(Path.join(File.cwd!(), relative_path))
    {:ok, ast} = Code.string_to_quoted(source)

    handled = collect_handled_tags(ast) |> MapSet.new()
    missing = MapSet.difference(MapSet.new(required_tags), handled)

    assert MapSet.size(missing) == 0,
           "#{relative_path} subscribes to topics that publish these tags, " <>
             "but has no matching handle_info clause: #{inspect(MapSet.to_list(missing))}. " <>
             "Either add a handler or remove the tag from the required list with a " <>
             "comment explaining why the drop is intentional."
  end

  # Walks the AST collecting atoms pulled from handle_info clauses.
  # Three shapes to cover:
  #   1. `def handle_info({:tag, ...}, socket) do ... end`
  #      → AST:`{:def, _, [{:handle_info, _, [pattern, _]}, _]}`
  #   2. `def handle_info({:tag, ...}, socket) when some_guard do ... end`
  #      → AST: `{:def, _, [{:when, _, [{:handle_info, _, [pattern, _]}, guard]}, _]}`
  #   3. Guarded-dispatch shape used by project_live:
  #      `def handle_info({event, _}, socket) when event in [:a, :b, :c] do`
  #      Pattern's first element is a var, but the guard's list carries
  #      the real tags — extract from both.
  defp collect_handled_tags(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:handle_info, _, [pattern | _]} | _]} = node, acc ->
          {node, acc ++ tags_from_pattern(pattern)}

        {:def, _, [{:when, _, [{:handle_info, _, [pattern | _]}, guard]} | _]} = node,
        acc ->
          {node, acc ++ tags_from_pattern(pattern) ++ tags_from_guard(guard)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # 3+-tuple literal: `{:{}, _, [tag, ...]}` where tag must be an atom.
  defp tags_from_pattern({:{}, _, [tag | _]}) when is_atom(tag), do: [tag]

  # 2-tuple literal: compiles to `{tag, payload}` directly (no `:{}` wrapper).
  defp tags_from_pattern({tag, _}) when is_atom(tag), do: [tag]

  defp tags_from_pattern(_), do: []

  # Guard is an AST subtree. For `event in [:a, :b]` the shape is
  # `{:in, _, [_var, [:a, :b, :c]]}`. Walk until we find an `in` whose
  # right-hand is a literal list, and pull the atom elements.
  defp tags_from_guard(guard) do
    {_, acc} =
      Macro.prewalk(guard, [], fn
        {:in, _, [_var, list]} = node, acc when is_list(list) ->
          {node, acc ++ Enum.filter(list, &is_atom/1)}

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
