defmodule Loopyard.Saga.JournalTest do
  use ExUnit.Case, async: false

  alias Loopyard.Saga
  alias Loopyard.Saga.Journal

  setup do
    # Isolate every test behind its own LOOPYARD_HOME so the journal
    # file doesn't leak between tests. Reset the per-process env var
    # on exit.
    prev_home = System.get_env("LOOPYARD_HOME")

    tmp = Path.join(System.tmp_dir!(), "saga_journal_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("LOOPYARD_HOME", tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      case prev_home do
        nil -> System.delete_env("LOOPYARD_HOME")
        val -> System.put_env("LOOPYARD_HOME", val)
      end
    end)

    %{tmp: tmp, path: Journal.path()}
  end

  describe "path/0" do
    test "resolves under LOOPYARD_HOME", %{tmp: tmp, path: path} do
      assert Path.dirname(path) == tmp
      assert Path.basename(path) == "sagas.log"
    end
  end

  describe "append/1 + trace/1" do
    test "appended records come back via trace/1" do
      Journal.append(
        {:saga_started, 42, :my_saga, %{ws: "a"}, :rollback, [:one, :two],
         System.system_time(:millisecond)}
      )

      Journal.append({:step_started, 42, :one, %{}})
      Journal.append({:step_succeeded, 42, :one, %{one: :ok}})
      Journal.append({:saga_completed, 42})

      trace = Journal.trace(42)
      assert length(trace) == 4
      assert hd(trace) |> elem(0) == :saga_started
      assert List.last(trace) == {:saga_completed, 42}
    end

    test "trace for unknown saga is empty" do
      assert Journal.trace(9_999) == []
    end
  end

  describe "incomplete/0" do
    test "returns sagas with :saga_started and no terminal record" do
      Journal.append(
        {:saga_started, 1, :boot_agent, %{agent_id: "a1"}, :rollback, [:step1, :step2], 100}
      )

      Journal.append({:step_started, 1, :step1, %{}})
      Journal.append({:step_succeeded, 1, :step1, %{step1: :ok}})
      Journal.append({:step_started, 1, :step2, %{}})

      incomplete = Journal.incomplete()
      assert length(incomplete) == 1
      [saga] = incomplete
      assert saga.saga_id == 1
      assert saga.name == :boot_agent
      assert saga.on_resume == :rollback
      assert saga.metadata == %{agent_id: "a1"}
      assert saga.completed_steps == [:step1]
      assert saga.started_step == :step2
      assert saga.status == :in_flight
    end

    test "sagas with :saga_completed are excluded" do
      Journal.append({:saga_started, 2, :done_saga, %{}, :rollback, [:s1], 100})

      Journal.append({:step_started, 2, :s1, %{}})
      Journal.append({:step_succeeded, 2, :s1, %{}})
      Journal.append({:saga_completed, 2})

      assert Journal.incomplete() == []
    end

    test "sagas with :saga_rolled_back are excluded" do
      Journal.append({:saga_started, 3, :rb_saga, %{}, :rollback, [:s1], 100})

      Journal.append({:step_started, 3, :s1, %{}})
      Journal.append({:step_failed, 3, :s1, "boom"})
      Journal.append({:saga_rolled_back, 3, {:step_failed, :s1, "boom"}})

      assert Journal.incomplete() == []
    end

    test "multiple in-flight sagas returned sorted chronologically (oldest first)" do
      # Audit-2 LOW #11/#12: sort key is now {started_at_ms, saga_id}
      # so ordering survives a future saga_id format change and handles
      # the pre-commit 02d42f6 integer ids + post-commit string ids
      # mixing cleanly. Started_at values are 1/2/3 → that's the sort
      # order, regardless of the saga_ids.
      Journal.append({:saga_started, 10, :a, %{}, :rollback, [:x], 1})
      Journal.append({:saga_started, 5, :b, %{}, :rollback, [:y], 2})
      Journal.append({:saga_started, 7, :c, %{}, :rollback, [:z], 3})

      ids = Journal.incomplete() |> Enum.map(& &1.saga_id)
      assert ids == [10, 5, 7]
    end

    test "sort is stable for out-of-order started_at timestamps" do
      # Audit-2 LOW #11 regression guard. Deliberately feed sagas in
      # arbitrary id+timestamp order; the chronological result must
      # come out oldest-first regardless of insertion order.
      Journal.append({:saga_started, "zz-3", :c, %{}, :rollback, [:x], 300})
      Journal.append({:saga_started, "aa-1", :a, %{}, :rollback, [:y], 100})
      Journal.append({:saga_started, "mm-2", :b, %{}, :rollback, [:z], 200})

      ids = Journal.incomplete() |> Enum.map(& &1.saga_id)
      assert ids == ["aa-1", "mm-2", "zz-3"]
    end
  end

  describe "Saga.run/2 with journaling" do
    test "happy path leaves no incomplete sagas" do
      steps = [
        %{name: :a, run: fn _ -> {:ok, %{a: 1}} end},
        %{name: :b, run: fn _ -> {:ok, %{b: 2}} end}
      ]

      assert {:ok, _} = Saga.run(steps, name: :happy_saga, journal?: true)
      assert Journal.incomplete() == []
    end

    test "failure + successful rollback leaves no incomplete sagas" do
      steps = [
        %{name: :a, run: fn _ -> {:ok, %{}} end, rollback: fn _ -> :ok end},
        %{name: :b, run: fn _ -> {:error, :boom} end}
      ]

      assert {:error, _, :rolled_back} = Saga.run(steps, name: :rb_saga, journal?: true)
      assert Journal.incomplete() == []
    end

    test "journal?: false skips journaling entirely" do
      steps = [%{name: :a, run: fn _ -> {:ok, %{}} end}]

      assert {:ok, _} = Saga.run(steps, name: :skipped, journal?: false)

      # Journal file should either not exist or contain no saga records.
      # (An existing file from a prior test's append() would have records;
      # in this isolated test it shouldn't exist at all.)
      assert File.stat(Journal.path()) == {:error, :enoent}
    end

    test "crash mid-step leaves an in-flight journal entry" do
      # Simulate a crash BEFORE the saga ever records :step_succeeded
      # or :step_failed. We do this by writing :saga_started and
      # :step_started manually (as if Saga.run recorded those and then
      # the BEAM died before it could record the step outcome). This
      # is exactly the shape "kill -9 mid-step" leaves on disk.
      saga_id = :erlang.unique_integer([:positive, :monotonic])

      Journal.append({:saga_started, saga_id, :crashy, %{ws: "w1"}, :rollback, [:a, :b], 0})

      Journal.append({:step_started, saga_id, :a, %{}})

      incomplete = Journal.incomplete()
      assert Enum.any?(incomplete, &(&1.saga_id == saga_id))
      [saga] = Enum.filter(incomplete, &(&1.saga_id == saga_id))
      assert saga.started_step == :a
      assert saga.completed_steps == []
    end

    test "on_resume option is recorded in the journal" do
      steps = [
        %{name: :a, run: fn _ -> {:error, :halt} end}
      ]

      # Force a rollback so the saga is terminal (otherwise the ad-hoc
      # crash we're not simulating would leave it in flight).
      assert {:error, _, :rolled_back} =
               Saga.run(steps, name: :strat_saga, on_resume: :manual, journal?: true)

      # Pull all records back, find the :saga_started, and verify.
      records = Journal.all_sagas()
      saga = Enum.find(records, &(&1.name == :strat_saga))
      assert saga.on_resume == :manual
    end
  end

  describe "resume_all_on_boot/0" do
    test "rolls back in-flight sagas with :rollback strategy" do
      # Insert two crashed sagas directly.
      sid1 = :erlang.unique_integer([:positive, :monotonic])
      sid2 = :erlang.unique_integer([:positive, :monotonic])

      Journal.append({:saga_started, sid1, :crashy1, %{}, :rollback, [:a], 0})

      Journal.append({:step_started, sid1, :a, %{}})

      Journal.append({:saga_started, sid2, :crashy2, %{}, :manual, [:a], 0})

      Journal.append({:step_started, sid2, :a, %{}})

      summary = Journal.resume_all_on_boot()

      assert summary.incomplete == 2
      assert summary.rolled_back == 1
      assert summary.manual == 1

      # Let the dispatched rollback tasks run.
      Process.sleep(50)

      # After resume, :rollback sagas should now be terminal, :manual
      # ones should still be in flight.
      remaining_ids = Journal.incomplete() |> Enum.map(& &1.saga_id)
      assert sid1 not in remaining_ids
      assert sid2 in remaining_ids
    end

    test "no incomplete sagas is a no-op" do
      assert %{incomplete: 0, rolled_back: 0, resumed: 0, manual: 0} =
               Journal.resume_all_on_boot()
    end
  end

  describe "compact/0" do
    test "drops finished sagas beyond the per-name tail, keeps in-flight" do
      # 10 finished :foo sagas — only the last 5 per name should remain
      # after compact/0.
      for i <- 1..10 do
        Journal.append({:saga_started, i, :foo, %{}, :rollback, [:a], i})
        Journal.append({:step_started, i, :a, %{}})
        Journal.append({:step_succeeded, i, :a, %{}})
        Journal.append({:saga_completed, i})
      end

      # One in-flight saga that must survive.
      Journal.append({:saga_started, 999, :live, %{}, :rollback, [:a], 999})
      Journal.append({:step_started, 999, :a, %{}})

      assert {:ok, %{kept: _, dropped: dropped}} = Journal.compact()
      assert dropped > 0

      all = Journal.all_sagas()
      live = Enum.find(all, &(&1.saga_id == 999))
      assert live, "in-flight saga was dropped by compaction"
      assert live.status == :in_flight

      finished = Enum.filter(all, &(&1.name == :foo))
      assert length(finished) <= 5
    end

    test "cheap no-op on missing file" do
      assert {:ok, %{before: 0, after: 0}} = Journal.compact()
    end
  end

  describe "corruption handling" do
    test "truncated trailing bytes are silently ignored (no crash)" do
      Journal.append({:saga_started, 1, :ok_saga, %{}, :rollback, [:a], 0})

      Journal.append({:step_started, 1, :a, %{}})
      Journal.append({:step_succeeded, 1, :a, %{}})

      # Write some garbage bytes to the end of the file — simulates
      # a mid-record crash where a new record started appending but
      # the process died before the full bytes hit disk.
      path = Journal.path()
      File.write!(path, <<0xDE, 0xAD, 0xBE>>, [:append, :raw])

      # Reading should not raise; dangling bytes are ignored. Valid
      # prior records survive unchanged.
      trace = Journal.trace(1)

      assert Enum.any?(trace, fn
               {:saga_started, 1, _, _, _, _, _} -> true
               _ -> false
             end)

      # All three committed records should still be readable.
      assert length(trace) == 3
    end

    test "length-prefix lying about size (claims more than file has)" do
      Journal.append({:saga_started, 1, :ok, %{}, :rollback, [:a], 0})

      path = Journal.path()
      # Append a bogus length prefix that says "9999 bytes follow"
      # with no content. read_entries/2 must stop cleanly.
      File.write!(path, <<9999::32>>, [:append, :raw])

      # Not crashing is the assertion. incomplete/0 reads the whole
      # file.
      assert [_] = Journal.incomplete()
    end

    test "empty file is valid" do
      File.write!(Journal.path(), "")
      assert Journal.incomplete() == []
      assert Journal.trace(1) == []
    end

    test "missing file is valid" do
      assert Journal.incomplete() == []
      assert Journal.trace(1) == []
    end
  end
end
