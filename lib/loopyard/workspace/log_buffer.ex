defmodule Loopyard.Workspace.LogBuffer do
  @moduledoc """
  Per-workspace service-log tailer + persistent ring buffer.

  The old service-log view POLLED `docker logs --tail` on a service's *current*
  container every few seconds. When a service crashed and Docker recreated the
  container, that pointer moved to the new (empty) container and the crash output
  vanished — the view went blank exactly when you needed it.

  Instead, this streams `docker logs -f --timestamps` for every running service
  into an ETS ring buffer (the last `@cap` frames per service). The buffer lives
  in Loopyard, not the container, so it OUTLIVES a crash: when a container exits,
  `docker logs -f` flushes its final output into the buffer before the port
  closes, and it stays there.

  Every frame is tagged with a `run` number — bumped each time we (re)attach to a
  container — so the UI can group frames by run and draw the crash/restart
  boundaries (run 1 crashed → run 2 crashed → run 3 running).

  One GenServer per workspace, supervised by `WorkspaceGroup`. Reads go straight
  to ETS (`frames/2`) — no GenServer round-trip.
  """
  use GenServer
  require Logger

  alias Loopyard.Docker
  alias Loopyard.Docker.Observer

  @table :service_log_frames
  # Max frames kept per service. Old frames drop off the front. "1000 or
  # whatever" — enough to hold a crash + a few restarts of context.
  @cap 1000
  # How many historical lines to grab when we first attach to a container.
  @tail 500
  @reconcile_ms 2_000

  # ---- API ----

  def start_link(opts) do
    # Unnamed: one per WorkspaceGroup supervisor, and reads go straight to ETS,
    # so nothing needs to locate this process by name.
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Buffered frames for a service, oldest→newest. Each frame is
  `%{seq, run, ts, text}`. Reads ETS directly — safe from any process.
  """
  @spec frames(String.t(), String.t()) :: [map()]
  def frames(workspace_id, service_name) do
    case :ets.lookup(@table, {workspace_id, service_name}) do
      [{_key, %{frames: rev}}] -> Enum.reverse(rev)
      _ -> []
    end
  rescue
    # Table not created yet (e.g. before a StateKeeper restart picks it up).
    ArgumentError -> []
  end

  @doc "Buffered frames grouped into consecutive runs: `[%{run, frames}]`."
  @spec grouped(String.t(), String.t()) :: [%{run: integer(), frames: [map()]}]
  def grouped(workspace_id, service_name) do
    workspace_id
    |> frames(service_name)
    |> Enum.chunk_by(& &1.run)
    |> Enum.map(fn [%{run: run} | _] = fs -> %{run: run, frames: fs} end)
  end

  # ---- GenServer ----

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    # Kick off shortly after start so the workspace's containers are visible.
    Process.send_after(self(), :reconcile, 300)
    {:ok, %{workspace_id: workspace_id, tails: %{}}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Process.send_after(self(), :reconcile, @reconcile_ms)
    {:noreply, reconcile(state)}
  end

  # A chunk of log bytes from one tail's port.
  def handle_info({port, {:data, bytes}}, state) when is_port(port) do
    case Enum.find(state.tails, fn {_svc, t} -> t.port == port end) do
      {service, tail} -> {:noreply, safe_ingest(state, service, tail, bytes)}
      nil -> {:noreply, state}
    end
  end

  # The tail's `docker logs -f` exited — the container stopped or was removed.
  # Keep the buffer; drop the tail so the next reconcile re-attaches (new run)
  # if the service comes back.
  def handle_info({port, {:exit_status, _code}}, state) when is_port(port) do
    tails =
      state.tails
      |> Enum.reject(fn {_svc, t} -> t.port == port end)
      |> Map.new()

    {:noreply, %{state | tails: tails}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tails, fn {_svc, t} -> safe_close(t.port) end)
    :ok
  end

  # ---- reconcile: keep one tail per running service ----

  defp reconcile(state) do
    running =
      state.workspace_id
      |> Observer.services_for()
      |> Enum.filter(&(&1.status == :running and is_binary(&1.container)))

    Enum.reduce(running, state, fn svc, st ->
      if Map.has_key?(st.tails, svc.name), do: st, else: start_tail(st, svc)
    end)
  catch
    # Observer/docker hiccup — try again next tick rather than crashing.
    :exit, _ -> state
  end

  defp start_tail(state, svc) do
    args = ["logs", "-f", "--timestamps", "--tail", to_string(@tail), svc.container]

    case Docker.open_port(args) do
      {:error, _} ->
        state

      port ->
        run = bump_run(state.workspace_id, svc.name)
        tail = %{port: port, run: run, container: svc.container, partial: ""}
        %{state | tails: Map.put(state.tails, svc.name, tail)}
    end
  end

  # ---- frame ingestion ----

  # A malformed chunk must never crash us (WorkspaceGroup is :one_for_all, so a
  # crash here would restart agents). On any error, keep the buffer as-is.
  defp safe_ingest(state, service, tail, bytes) do
    ingest(state, service, tail, bytes)
  rescue
    e ->
      Logger.warning("[LogBuffer] ingest failed for #{service}: #{inspect(e)}")
      state
  end

  # Split a byte chunk into whole lines (carrying a partial across chunks),
  # turn each into a frame, and append them to the ring buffer in one ETS write.
  defp ingest(state, service, tail, bytes) do
    data = tail.partial <> bytes
    parts = String.split(data, "\n")
    {complete, [partial]} = Enum.split(parts, -1)

    frames =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_line(&1, tail.run))

    unless frames == [], do: append(state.workspace_id, service, frames)

    tails = Map.put(state.tails, service, %{tail | partial: partial})
    %{state | tails: tails}
  end

  # `--timestamps` prefixes each line with an RFC3339 timestamp + a space. Keep
  # the rest verbatim (it may carry the in-container process prefix like
  # "web.1 | ..."). run is threaded through for UI grouping; seq is assigned on
  # append so it's globally monotonic per service.
  defp parse_line(line, run) do
    case String.split(line, " ", parts: 2) do
      [ts, text] -> %{ts: ts, text: text, run: run}
      [only] -> %{ts: nil, text: only, run: run}
    end
  end

  defp append(workspace_id, service, new_frames) do
    key = {workspace_id, service}
    entry = read_entry(key)
    seq0 = entry.seq

    {frames_rev, seq} =
      Enum.reduce(new_frames, {entry.frames, seq0}, fn f, {acc, s} ->
        {[Map.put(f, :seq, s) | acc], s + 1}
      end)

    frames_rev = Enum.take(frames_rev, @cap)
    :ets.insert(@table, {key, %{entry | frames: frames_rev, seq: seq}})
  end

  # Bump the run counter on (re)attach, persisted in the ETS entry so it's stable
  # across GenServer restarts.
  defp bump_run(workspace_id, service) do
    key = {workspace_id, service}
    entry = read_entry(key)
    run = entry.run + 1
    :ets.insert(@table, {key, %{entry | run: run}})
    run
  end

  defp read_entry(key) do
    case :ets.lookup(@table, key) do
      [{_key, entry}] -> entry
      _ -> %{frames: [], seq: 0, run: 0}
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
  catch
    _, _ -> :ok
  end
end
