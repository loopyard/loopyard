defmodule Loopyard.ChatAgent.ModeControl do
  @moduledoc """
  The composer's Discuss / Build switch, agent-side.

  Two settings, one harness mechanism: **Discuss** puts the live session in
  the harness's PLAN mode (it reads, thinks and talks — it cannot edit);
  **Build** returns it to the mode it booted in. The setting is Loopyard
  state — persisted on the agent (`mode: :discuss | :build`), broadcast to
  every viewer, and re-applied to every fresh or resumed session through
  `session_opts[:mode]` — exactly how `ModelControl` carries the model.

  The harness's vocabulary for "plan mode" never leaves the backend:
  `capture/1` asks it after each session start (`backend.modes/1`) and keeps
  the advertised plan mode's id on the agent as `plan_mode_id` (nil = this
  harness has no plan mode, and the composer hides the switch).
  """

  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events

  @ets_table :chat_agents

  @type setting :: :discuss | :build

  @doc ~S|Parse a UI value (`"discuss"` / `"build"`, atoms too) into a setting.|
  @spec parse(term()) :: {:ok, setting()} | :error
  def parse(v) when v in [:discuss, "discuss"], do: {:ok, :discuss}
  def parse(v) when v in [:build, "build"], do: {:ok, :build}
  def parse(_), do: :error

  @doc """
  Apply `setting` to the live session and persist it. Returns the updated
  state (ETS + ETF log + broadcast side effects done). Discuss on a harness
  without a plan mode is a no-op that stays on Build.
  """
  @spec switch(map(), setting()) :: map()
  def switch(state, setting) when setting in [:discuss, :build] do
    plan = Map.get(state, :plan_mode_id)

    if setting == :discuss and is_nil(plan),
      do: state,
      else: apply_setting(state, setting, plan)
  end

  defp apply_setting(state, setting, plan) do
    if state.session && exported?(state.backend, :set_mode, 2) do
      case harness_mode(state, setting) do
        mode_id when is_binary(mode_id) -> state.backend.set_mode(state.session, mode_id)
        _ -> :ok
      end
    end

    session_opts =
      case setting do
        :discuss -> Keyword.put(state.session_opts || [], :mode, plan)
        :build -> Keyword.delete(state.session_opts || [], :mode)
      end

    state = %{state | session_opts: session_opts} |> Map.put(:mode, setting)

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})
    Loopyard.EventLog.info("agent:#{state.name}", "Mode switched to #{label(setting)}")
    state
  end

  @doc """
  Post-start bookkeeping: learn what the new session advertises. Sets
  `plan_mode_id` from the backend's mode list; a Discuss setting the harness
  can't honour (no plan mode) falls back to Build so the UI never shows a
  switch the session can't act on. Backends without `modes/1` leave the
  fields untouched.
  """
  @spec capture(map()) :: map()
  def capture(%{session: session, backend: backend} = state)
      when not is_nil(session) and not is_nil(backend) do
    if exported?(backend, :modes, 1) do
      modes = safe_modes(backend, session)
      plan = modes[:plan]

      state = Map.put(state, :plan_mode_id, plan)

      if is_nil(plan) and Map.get(state, :mode) == :discuss,
        do:
          Map.put(state, :mode, :build)
          |> Map.update!(:session_opts, &Keyword.delete(&1 || [], :mode)),
        else: state
    else
      state
    end
  end

  def capture(state), do: state

  @doc "Human label for a setting (the hero facts line, the event log)."
  def label(:discuss), do: "Discuss"
  def label(_), do: "Build"

  # The harness mode id a setting maps to on THIS session: Discuss → the
  # advertised plan mode; Build → the mode the session booted in (the
  # harness's own default, read live so a vendor's name for it is never
  # hard-coded here).
  defp harness_mode(state, :discuss), do: Map.get(state, :plan_mode_id)

  defp harness_mode(state, :build) do
    case safe_modes(state.backend, state.session) do
      %{boot: boot} when is_binary(boot) -> boot
      _ -> nil
    end
  end

  defp safe_modes(backend, session) do
    backend.modes(session)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp exported?(mod, fun, arity),
    do: is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
end
