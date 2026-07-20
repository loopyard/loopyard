defmodule Loopyard.Events.Activity do
  @moduledoc """
  The live activity backbone (#54): a single stream any view or subscriber can
  consume to get agent activity **across all projects** and **per project**,
  without subscribing to N per-agent topics.

  Two topics:
    * global `"activity"` — every agent's status changes + tool calls, everywhere.
    * per-project `"project_activity:<project_id>"` — just that project's.

  Each event (`Loopyard.Events.Activity.Event`) is tagged with project/workspace/
  agent, so consumers can weight by proximity — the god-mode sidebar (#55),
  the Foreman's read-only view (#59), and the activity sound layer (#61) all
  ride this one stream. Producers call `record/3`; the enrichment (name,
  workspace, project) is read from `:chat_agents` ETS here so callers stay thin.

  Per the pubsub boundary rule, this module is the ONLY place that broadcasts
  activity — callers use `record/3`, never `Phoenix.PubSub.broadcast` directly.
  """
  alias Loopyard.Events.Activity.Event

  @global_topic "activity"
  @telemetry [:loopyard, :events, :publish]

  @doc "Global activity topic name."
  def global_topic, do: @global_topic

  @doc "Per-project activity topic name."
  def project_topic(project_id), do: "project_activity:#{project_id}"

  @doc "Subscribe to every agent's activity across all projects."
  def subscribe_global, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @global_topic)

  @doc "Subscribe to one project's activity."
  def subscribe_project(project_id),
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, project_topic(project_id))

  @doc """
  Record an activity for an agent. Enriches name/workspace/project from
  `:chat_agents` ETS and broadcasts to the global topic plus the agent's
  project topic. Cheap and crash-safe — a missing/unknown agent is a no-op,
  never an error (activity is observability, it must not break a turn).
  """
  def record(agent_id, kind, summary) when is_binary(agent_id) do
    case lookup(agent_id) do
      nil ->
        :ok

      summary_map ->
        ws_id = Map.get(summary_map, :workspace_id)

        publish(%Event{
          agent_id: agent_id,
          agent_name: Map.get(summary_map, :name),
          workspace_id: ws_id,
          project_id: project_id_for(ws_id),
          kind: kind,
          summary: to_string(summary),
          at: DateTime.utc_now()
        })
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def record(_, _, _), do: :ok

  @doc "Broadcast a prebuilt Activity event (global + its project topic)."
  def publish(%Event{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @global_topic, event: Event})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @global_topic, e)
    if e.project_id, do: Phoenix.PubSub.broadcast(Loopyard.PubSub, project_topic(e.project_id), e)
    :ok
  end

  defp lookup(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] -> summary
      _ -> nil
    end
  end

  defp project_id_for(nil), do: nil

  defp project_id_for(workspace_id) do
    case Loopyard.WorkspaceRegistry.get_workspace(workspace_id) do
      %{} = ws -> ws[:project_id]
      _ -> nil
    end
  end
end
