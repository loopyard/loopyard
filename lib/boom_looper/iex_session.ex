defmodule BoomLooper.IExSession do
  @moduledoc """
  Tracks operator presence via IEx/RPC for UI visibility.

  Traffic light system for humans:
  - :green  = "Operator connected, just watching" - safe to work
  - :yellow = "Operator doing things" - stuff might change
  - :red    = "Operator destroying things" - stop, your work might get blown away

  Usage from IEx:

      # Just connected, watching
      IExSession.watching()

      # Doing something
      IExSession.working("running eval for foo")

      # About to destroy stuff
      IExSession.destructive("wiping all volumes")

      # Wrap a function (auto yellow -> green)
      IExSession.run("running eval", fn -> EvalRunner.run(path) end)

      # Wrap destructive operation (auto red -> green)
      IExSession.run!("wiping project", fn -> ProjectRegistry.remove(id) end)

      # Claim the session (prevents auto-disconnect by RPC)
      IExSession.claim()

      # Disconnect
      IExSession.disconnect()
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- Public API ---

  @doc "Just watching, not touching anything. Green light."
  def watching(note \\ nil) do
    set(:green, note || "Connected")
  end

  @doc "Actively doing things. Yellow light."
  def working(what) do
    set(:yellow, what)
  end

  @doc "About to destroy/reset things. Red light."
  def destructive(what) do
    set(:red, what)
  end

  @doc "Claim the session. Prevents disconnect_unless_claimed from clearing it."
  def claim do
    GenServer.cast(__MODULE__, :claim)
  end

  @doc "Clear presence (always works, clears claim)."
  def disconnect do
    GenServer.cast(__MODULE__, :disconnect)
  end

  @doc "Clear presence only if not claimed. Used by RPC to allow long-running tasks to keep the session."
  def disconnect_unless_claimed do
    GenServer.cast(__MODULE__, :disconnect_unless_claimed)
  end

  @doc "Get current session state."
  def current do
    GenServer.call(__MODULE__, :current)
  catch
    :exit, _ -> %{level: nil, label: nil, node: nil, at: nil}
  end

  @doc "Wrap a function with yellow status, returns to green after."
  def run(label, fun) do
    working(label)

    try do
      fun.()
    after
      watching()
    end
  end

  @doc "Wrap a destructive function with red status, returns to green after."
  def run!(label, fun) do
    destructive(label)

    try do
      fun.()
    after
      watching()
    end
  end

  # --- Internal ---

  defp set(level, label) do
    GenServer.cast(__MODULE__, {:set, level, label, node()})
  end

  # --- GenServer ---

  def init(_) do
    {:ok, %{level: nil, label: nil, node: nil, at: nil, claimed: false}}
  end

  def handle_cast({:set, level, label, node}, state) do
    state = %{state | level: level, label: label, node: node, at: DateTime.utc_now()}
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:claim, state) do
    {:noreply, %{state | claimed: true}}
  end

  def handle_cast(:disconnect, _state) do
    state = %{level: nil, label: nil, node: nil, at: nil, claimed: false}
    broadcast(state)
    {:noreply, state}
  end

  def handle_cast(:disconnect_unless_claimed, %{claimed: true} = state) do
    # Session is claimed by a long-running task, don't disconnect
    {:noreply, state}
  end

  def handle_cast(:disconnect_unless_claimed, _state) do
    # Not claimed, safe to disconnect
    state = %{level: nil, label: nil, node: nil, at: nil, claimed: false}
    broadcast(state)
    {:noreply, state}
  end

  # Catchall handle_cast — stays grouped with the above.
  def handle_cast(_msg, state), do: {:noreply, state}

  def handle_call(:current, _from, state) do
    {:reply, Map.drop(state, [:claimed]), state}
  end

  # Catchall handle_call + handle_info.
  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(state) do
    # Don't include claimed in broadcast - it's internal state
    BoomLooper.Events.IexSession.publish(%BoomLooper.Events.IexSession.Changed{
      state: Map.drop(state, [:claimed])
    })
  end
end
