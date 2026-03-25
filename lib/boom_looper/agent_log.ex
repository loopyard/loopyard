defmodule BoomLooper.AgentLog do
  @moduledoc """
  Append-only log for persisting agent state.

  Uses ETF (Erlang Term Format) for fast serialization of native Elixir types.
  Log format: length-prefixed binary records.

  Each record: [4 bytes: size][N bytes: ETF binary]

  ## Versioning

  Version is **required** in all API calls. This is intentional - we want the
  application to be explicit about what version it expects, not auto-detect.

  First record in files is a meta record:
  `{:log_meta, %{version: 1, created_at: ~U[...]}}`

  Version mismatch returns `{:error, {:version_mismatch, file: X, requested: Y}}`
  rather than crashing. This allows graceful handling (show error, run migration).

  ### When to bump version

  - **DO bump**: Structural changes to event tuples (adding/removing elements,
    changing tuple structure, renaming event types)
  - **DON'T bump**: Adding new keys to maps within events. Maps are extensible -
    old code ignores unknown keys, new code handles missing keys with defaults.

  ### Why version is required (not auto-detected)

  Auto-detection hides version mismatches until runtime failures. By requiring
  the version in every call, mismatches are caught immediately with clear errors.
  The app knows what version it speaks; the file knows what version it contains.

  ## Migrations

  When you need to change the log format:

  1. Define a transformer function: `transform_v1_to_v2(event) -> event`
  2. Call `migrate(path, from: 1, to: 2, transformer: &transform_v1_to_v2/1)`
  3. Migration is atomic - uses temp file + rename, so crash = original preserved

  The `peek/1` function exists specifically to support migrations - it reads
  any version file without checking, which is what a migrator needs.

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
  Peek at a log file without version checking.

  For debugging and migrations - reads any version file regardless of what
  version the application expects. This is the only function that doesn't
  require a version parameter.

  Returns `{:ok, %{version: N, created_at: DateTime, events: [...]}}` or `{:error, reason}`.
  """
  def peek(opts) do
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
  Migrate a log file from one version to another.

  ## How it works

  1. Reads the entire file using `inspect/1` (version-agnostic)
  2. Verifies the file is at the expected `from` version
  3. Transforms each event using the provided transformer function
  4. Writes all transformed events to a temp file with the `to` version
  5. Atomically renames temp file to original path

  ## Atomicity / Crash Safety

  The migration is crash-safe because:
  - Original file is never modified in place
  - New content is written to a `.migrating` temp file
  - `File.rename/2` is atomic on POSIX systems
  - If crash occurs during write, original file is untouched
  - Either you have the complete old file or the complete new file

  ## Options

  - :log_path - path to log file (required)
  - :from - expected current version (required)
  - :to - target version (required)
  - :transformer - function to transform each event (required)
    Signature: `(event :: tuple()) :: tuple()`

  ## Returns

  - `:ok` - migration successful
  - `{:error, :file_not_found}` - no file at path
  - `{:error, {:unexpected_version, got: X, expected: Y}}` - file isn't at `from` version
  - `{:error, reason}` - other file errors

  ## Example

  ```elixir
  # Migrating from v1 to v2 where we rename :msg to :message
  transformer = fn
    {:msg, agent_id, data} -> {:message, agent_id, data}
    other -> other
  end

  AgentLog.migrate(path,
    from: 1,
    to: 2,
    transformer: transformer
  )
  ```
  """
  def migrate(opts) do
    path = Keyword.fetch!(opts, :log_path)
    from_version = Keyword.fetch!(opts, :from)
    to_version = Keyword.fetch!(opts, :to)
    transformer = Keyword.fetch!(opts, :transformer)

    case peek(log_path: path) do
      {:ok, %{version: nil}} ->
        {:error, :file_not_found}

      {:ok, %{version: version}} when version != from_version ->
        {:error, {:unexpected_version, got: version, expected: from_version}}

      {:ok, %{events: events}} ->
        do_migrate(path, to_version, events, transformer)

      {:error, _} = err ->
        err
    end
  end

  defp do_migrate(path, to_version, events, transformer) do
    temp_path = path <> ".migrating"
    dir = Path.dirname(temp_path)

    # Ensure directory exists (should already, but be safe)
    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end

    # Remove any leftover temp file from a previous failed migration
    File.rm(temp_path)

    # Write transformed events to temp file
    for event <- events do
      transformed = transformer.(event)
      append(transformed, log_path: temp_path, version: to_version)
    end

    # Atomic rename - this is the commit point
    # On POSIX systems, rename is atomic. Either the old file exists
    # or the new file exists, never an in-between state.
    case File.rename(temp_path, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, reason}}
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
