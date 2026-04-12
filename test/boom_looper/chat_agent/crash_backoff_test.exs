defmodule BoomLooper.ChatAgent.CrashBackoffTest do
  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent

  @moduletag timeout: 10_000

  setup do
    # Zero backoff so tests run instantly
    Application.put_env(:boom_looper, :crash_backoff_base_ms, 0)
    on_exit(fn -> Application.delete_env(:boom_looper, :crash_backoff_base_ms) end)

    id = "backoff-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Backoff Test",
        working_dir: File.cwd!(),
        started_by: "test"
      )

    ChatAgent.subscribe()
    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(50)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "crash backoff" do
    test "first crash restarts and increments counter", %{id: id} do
      pid = agent_pid(id)
      assert pid != nil

      # Put agent into :thinking state so it handles EXIT messages
      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking}
        |> Map.put(:consecutive_crashes, 0)
      end)

      # Simulate a linked task crash
      send(pid, {:EXIT, self(), {:error, "test crash"}})

      # Should get a status change back to :idle (restarted)
      assert_receive {:chat_agent_status_changed, ^id, :idle}, 1_000

      # Counter should be 1
      state = :sys.get_state(pid)
      assert Map.get(state, :consecutive_crashes) == 1
    end

    test "gives up after max consecutive crashes", %{id: id} do
      pid = agent_pid(id)

      # Fast-forward the crash counter to just below the limit
      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking}
        |> Map.put(:consecutive_crashes, 5)
      end)

      # One more crash should trigger the "give up" path
      send(pid, {:EXIT, self(), {:error, "fatal crash"}})

      # Should mark as :crashed, not :idle
      assert_receive {:chat_agent_status_changed, ^id, :crashed}, 1_000
    end

    test "successful stream_done resets crash counter", %{id: id} do
      pid = agent_pid(id)

      # Set some crash history
      :sys.replace_state(pid, fn state ->
        %{state | status: :thinking}
        |> Map.put(:consecutive_crashes, 3)
      end)

      # Simulate successful stream completion
      send(pid, {:stream_done, id})

      assert_receive {:chat_agent_status_changed, ^id, :idle}, 1_000

      state = :sys.get_state(pid)
      assert Map.get(state, :consecutive_crashes) == 0
    end
  end
end
