defmodule BoomLooper.AgentLog do
  @moduledoc """
  Append-only log for persisting agent state.

  Uses ETF (Erlang Term Format) for fast serialization of native Elixir types.
  Log format: length-prefixed binary records.

  Each record: [4 bytes: size][N bytes: ETF binary]

  ## Versioning

  Version is required in API calls. First record in files is a meta record:
  `{:log_meta, %{version: 1, created_at: ~U[...]}}`

  Version mismatch returns `{:error, {:version_mismatch, file: X, requested: Y}}`

  ## Event types

  - {:agent, agent_id, agent_data} - Agent created/updated
  - {:msg, agent_id, message} - Message appended
  - {:msg_update, agent_id, msg_id, changes} - Message updated

  On boot, replay the log to restore ETS state.
  """

  @doc """
  Append an event to the log file.

  Writes version header on first append to new/empty file.

  Options:
  - :log_path - path to log file (required)
  - :version - log version (required)
  """
  def append(event, opts) do
    path = Keyword.fetch!(opts, :log_path)
    version = Keyword.fetch!(opts, :version)
    dir = Path.dirname(path)

    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end

    # Write version header if file doesn't exist or is empty
    ensure_meta_header(path, version)

    write_record(path, event)
  end

  @doc """
  Replay the log file and apply events to rebuild state.

  Returns `{:ok, state}` on success.
  Returns `{:error, {:version_mismatch, file: X, requested: Y}}` if versions don't match.

  Options:
  - :log_path - path to log file (required)
  - :version - expected version (required)
  - :ets_table - ETS table to populate (optional)
  """
  def replay(opts) do
    path = Keyword.fetch!(opts, :log_path)
    requested_version = Keyword.fetch!(opts, :version)
    ets_table = Keyword.get(opts, :ets_table)

    case File.read(path) do
      {:ok, binary} ->
        case check_version_and_replay(binary, requested_version) do
          {:ok, state} ->
            if ets_table, do: populate_ets(ets_table, state)
            {:ok, state}

          {:error, _} = err ->
            err
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Inspect a log file without version checking.

  For debugging - reads any version file.

  Returns `{:ok, %{version: N, created_at: DateTime, events: [...]}}` or `{:error, reason}`.
  """
  def inspect(opts) do
    path = Keyword.fetch!(opts, :log_path)

    case File.read(path) do
      {:ok, binary} ->
        {meta, events} = read_all(binary)
        {:ok, Map.put(meta, :events, events)}

      {:error, :enoent} ->
        {:ok, %{version: nil, created_at: nil, events: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read all events from the log without applying them.
  Useful for debugging/inspection. Excludes meta record.
  """
  def read_events(opts) do
    path = Keyword.fetch!(opts, :log_path)

    case File.read(path) do
      {:ok, binary} ->
        {_meta, events} = read_all(binary)
        {:ok, events}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: Writing ---

  defp ensure_meta_header(path, version) do
    needs_header = case File.stat(path) do
      {:ok, %{size: 0}} -> true
      {:error, :enoent} -> true
      _ -> false
    end

    if needs_header do
      meta = {:log_meta, %{version: version, created_at: DateTime.utc_now()}}
      binary = :erlang.term_to_binary(meta)
      File.write!(path, <<byte_size(binary)::32, binary::binary>>, [:write, :raw])
    end
  end

  defp write_record(path, event) do
    binary = :erlang.term_to_binary(event)
    File.write!(path, <<byte_size(binary)::32, binary::binary>>, [:append, :raw])
  end

  # --- Private: Reading ---

  defp check_version_and_replay(binary, requested_version) do
    case read_meta(binary) do
      {:ok, %{version: file_version}, rest} when file_version == requested_version ->
        state = replay_entries(rest, %{})
        {:ok, state}

      {:ok, %{version: file_version}, _rest} ->
        {:error, {:version_mismatch, file: file_version, requested: requested_version}}

      {:error, :no_meta} ->
        # Legacy file (no meta record) - treat as version 0
        if requested_version == 0 do
          state = replay_entries(binary, %{})
          {:ok, state}
        else
          {:error, {:version_mismatch, file: 0, requested: requested_version}}
        end
    end
  end

  defp read_meta(<<size::32, rest::binary>>) when byte_size(rest) >= size do
    <<data::binary-size(size), remaining::binary>> = rest

    case safe_binary_to_term(data) do
      {:ok, {:log_meta, meta}} when is_map(meta) ->
        {:ok, meta, remaining}

      {:ok, _other} ->
        {:error, :no_meta}

      :error ->
        {:error, :no_meta}
    end
  end

  defp read_meta(_), do: {:error, :no_meta}

  defp read_all(binary) do
    case read_meta(binary) do
      {:ok, meta, rest} ->
        events = read_entries(rest, [])
        {meta, events}

      {:error, :no_meta} ->
        # Legacy file - no meta, all records are events
        events = read_entries(binary, [])
        {%{version: 0, created_at: nil}, events}
    end
  end

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
        {:ok, {:log_meta, _}} -> acc  # Skip meta record
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
    existing = Map.get(state, agent_id, %{messages: []})
    messages = Map.get(existing, :messages, [])
    updated = Map.put(agent_data, :messages, messages)
    Map.put(state, agent_id, updated)
  end

  defp apply_event({:msg, agent_id, msg}, state) do
    agent = Map.get(state, agent_id, %{messages: []})
    messages = Map.get(agent, :messages, [])
    updated = Map.put(agent, :messages, messages ++ [msg])
    Map.put(state, agent_id, updated)
  end

  defp apply_event({:msg_update, agent_id, msg_id, changes}, state) do
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
