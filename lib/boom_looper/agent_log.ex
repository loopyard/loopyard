defmodule BoomLooper.AgentLog do
  @moduledoc """
  Append-only log for persisting agent state.

  Uses ETF (Erlang Term Format) for fast serialization of native Elixir types.
  Log format: length-prefixed binary records.

  Each record: [4 bytes: size][N bytes: ETF binary]

  Event types:
  - {:agent, agent_id, agent_data} - Agent created/updated
  - {:msg, agent_id, message} - Message appended
  - {:msg_update, agent_id, msg_id, changes} - Message updated

  On boot, replay the log to restore ETS state.
  """

  @doc """
  Append an event to the log file.

  Options:
  - :log_path - path to log file (required)
  """
  def append(event, opts) do
    path = Keyword.fetch!(opts, :log_path)
    dir = Path.dirname(path)

    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end

    binary = :erlang.term_to_binary(event)
    File.write!(path, <<byte_size(binary)::32, binary::binary>>, [:append, :raw])
  end

  @doc """
  Replay the log file and apply events to rebuild state.

  Returns a map of agent_id => agent_data (including messages).

  Options:
  - :log_path - path to log file (required)
  - :ets_table - ETS table to populate (optional, if provided will write to ETS)
  """
  def replay(opts) do
    path = Keyword.fetch!(opts, :log_path)
    ets_table = Keyword.get(opts, :ets_table)

    case File.read(path) do
      {:ok, binary} ->
        state = replay_entries(binary, %{})

        if ets_table do
          populate_ets(ets_table, state)
        end

        {:ok, state}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read all events from the log without applying them.
  Useful for debugging/inspection.
  """
  def read_events(opts) do
    path = Keyword.fetch!(opts, :log_path)

    case File.read(path) do
      {:ok, binary} -> {:ok, read_entries(binary, [])}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private: Replay Logic ---

  defp replay_entries(<<size::32, rest::binary>>, state) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest

    state =
      case safe_binary_to_term(data) do
        {:ok, event} -> apply_event(event, state)
        :error -> state
      end

    replay_entries(remaining, state)
  end

  defp replay_entries(_, state), do: state

  defp read_entries(<<size::32, rest::binary>>, acc) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest

    acc =
      case safe_binary_to_term(data) do
        {:ok, event} -> [event | acc]
        :error -> acc
      end

    read_entries(remaining, acc)
  end

  defp read_entries(_, acc), do: Enum.reverse(acc)

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    ArgumentError -> :error
  end

  # --- Private: Event Application ---

  defp apply_event({:agent, agent_id, agent_data}, state) do
    # Upsert agent, preserving messages if they exist
    existing = Map.get(state, agent_id, %{messages: []})
    messages = Map.get(existing, :messages, [])
    updated = Map.put(agent_data, :messages, messages)
    Map.put(state, agent_id, updated)
  end

  defp apply_event({:msg, agent_id, msg}, state) do
    # Append message to agent
    agent = Map.get(state, agent_id, %{messages: []})
    messages = Map.get(agent, :messages, [])
    updated = Map.put(agent, :messages, messages ++ [msg])
    Map.put(state, agent_id, updated)
  end

  defp apply_event({:msg_update, agent_id, msg_id, changes}, state) do
    # Update existing message
    case Map.get(state, agent_id) do
      nil ->
        state

      agent ->
        messages =
          Enum.map(agent.messages, fn msg ->
            if msg[:id] == msg_id do
              Map.merge(msg, changes)
            else
              msg
            end
          end)

        Map.put(state, agent_id, Map.put(agent, :messages, messages))
    end
  end

  defp apply_event(_unknown, state), do: state

  # --- Private: ETS Population ---

  defp populate_ets(table, state) do
    for {agent_id, agent_data} <- state do
      :ets.insert(table, {agent_id, agent_data})
    end

    :ok
  end
end
