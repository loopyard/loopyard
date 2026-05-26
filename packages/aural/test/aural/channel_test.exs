defmodule Aural.ChannelTest do
  # Integration tests — spawn real Channel GenServers under the
  # package's DynamicSupervisor, talk to them through PubSub.
  # async: false because we share the singleton supervisor and
  # registry across tests and want predictable teardown.
  use ExUnit.Case, async: false

  alias Aural.Channel

  setup do
    # Stop every channel left running from previous tests; this
    # gives each test a clean registry to assert against.
    for {_id, pid} <- Channel.list() do
      Process.exit(pid, :shutdown)
    end

    # Wait for cleanup — Registry entries clear when the pid dies.
    Process.sleep(50)

    :ok
  end

  describe "new_id/0" do
    test "returns an 11-char url-safe string" do
      id = Channel.new_id()
      assert is_binary(id)
      assert byte_size(id) == 11
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, id)
    end

    test "is unique per call" do
      ids = for _ <- 1..100, do: Channel.new_id()
      assert length(Enum.uniq(ids)) == 100
    end
  end

  describe "valid_channel_id?/1" do
    test "accepts url-safe strings up to 64 chars" do
      assert Channel.valid_channel_id?("abc")
      assert Channel.valid_channel_id?("abc-DEF_123")
      assert Channel.valid_channel_id?(String.duplicate("a", 64))
    end

    test "rejects empty / oversize / non-url-safe / non-binary input" do
      refute Channel.valid_channel_id?("")
      refute Channel.valid_channel_id?(String.duplicate("a", 65))
      refute Channel.valid_channel_id?("has spaces")
      refute Channel.valid_channel_id?("../etc/passwd")
      refute Channel.valid_channel_id?(123)
      refute Channel.valid_channel_id?(nil)
    end
  end

  describe "ensure_started/1" do
    @tag :ffmpeg
    test "spawns a channel under the supervisor and is idempotent" do
      id = Channel.new_id()

      assert {:ok, pid} = Channel.ensure_started(id)
      assert Process.alive?(pid)

      # Second call returns the same pid — does NOT spawn a duplicate.
      assert {:ok, ^pid} = Channel.ensure_started(id)
    end

    @tag :ffmpeg
    test "different ids yield different pids" do
      id_a = Channel.new_id()
      id_b = Channel.new_id()

      {:ok, pid_a} = Channel.ensure_started(id_a)
      {:ok, pid_b} = Channel.ensure_started(id_b)

      assert pid_a != pid_b
    end

    test "rejects invalid channel_id without spawning" do
      assert Channel.ensure_started("has spaces") == {:error, :invalid_channel_id}
      assert Channel.ensure_started("") == {:error, :invalid_channel_id}
      assert Channel.ensure_started(String.duplicate("a", 65)) == {:error, :invalid_channel_id}
    end
  end

  describe "list/0" do
    @tag :ffmpeg
    test "enumerates active channels" do
      id_a = Channel.new_id()
      id_b = Channel.new_id()

      {:ok, _} = Channel.ensure_started(id_a)
      {:ok, _} = Channel.ensure_started(id_b)

      ids = Channel.list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert id_a in ids
      assert id_b in ids
    end
  end

  describe "fire/2" do
    @tag :ffmpeg
    test "caps active chimes at 16; oldest drops" do
      id = Channel.new_id()
      {:ok, pid} = Channel.ensure_started(id)

      # Fire 20 chimes back-to-back. The cast queue serializes so
      # they all hit handle_cast before the next :tick prunes.
      for _ <- 1..20, do: Channel.fire(id, "done")

      # Synchronize: a sync call drains all prior casts.
      _ = Channel.state(id)

      chimes = :sys.get_state(pid).chimes
      assert length(chimes) == 16
    end

    @tag :ffmpeg
    test "ignores unknown chime kinds" do
      id = Channel.new_id()
      {:ok, pid} = Channel.ensure_started(id)

      Channel.fire(id, "not-a-real-chime")
      _ = Channel.state(id)

      assert :sys.get_state(pid).chimes == []
    end
  end

  describe "pick_track/2" do
    @tag :ffmpeg
    test "switches to a known track" do
      id = Channel.new_id()
      {:ok, _} = Channel.ensure_started(id)

      Channel.pick_track(id, :nocturne)
      assert Channel.state(id).track == :nocturne
    end

    @tag :ffmpeg
    test "is a no-op for unknown tracks (no crash, no state change)" do
      id = Channel.new_id()
      {:ok, _} = Channel.ensure_started(id)

      before = Channel.state(id)
      Channel.pick_track(id, :definitely_not_a_real_track)
      assert Channel.state(id) == before
    end
  end

  describe "set_activity/2" do
    @tag :ffmpeg
    test "clamps to [0.0, 1.0]" do
      id = Channel.new_id()
      {:ok, _} = Channel.ensure_started(id)

      Channel.set_activity(id, 0.5)
      assert Channel.state(id).activity == 0.5

      Channel.set_activity(id, 1.5)
      assert Channel.state(id).activity == 1.0

      Channel.set_activity(id, -1.0)
      assert Channel.state(id).activity == 0.0
    end

    @tag :ffmpeg
    test "ignores non-numeric levels" do
      id = Channel.new_id()
      {:ok, _} = Channel.ensure_started(id)

      Channel.set_activity(id, 0.5)
      Channel.set_activity(id, "loud")
      assert Channel.state(id).activity == 0.5
    end
  end

  describe "telemetry" do
    @tag :ffmpeg
    test "emits [:aural, :channel, :start] on lazy spawn" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        ref,
        [:aural, :channel, :start],
        fn _event, _measurements, meta, _config ->
          send(test_pid, {ref, meta.channel_id})
        end,
        nil
      )

      id = Channel.new_id()
      {:ok, _} = Channel.ensure_started(id)

      assert_receive {^ref, ^id}, 1000

      :telemetry.detach(ref)
    end

    @tag :ffmpeg
    test "emits [:aural, :channel, :fire] with active_chimes count" do
      id = Channel.new_id()
      {:ok, _} = Channel.ensure_started(id)

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        ref,
        [:aural, :channel, :fire],
        fn _event, measurements, meta, _config ->
          send(test_pid, {ref, measurements, meta})
        end,
        nil
      )

      Channel.fire(id, "done")

      assert_receive {^ref, %{active_chimes: 1}, %{channel_id: ^id, kind: "done"}}, 1000

      :telemetry.detach(ref)
    end
  end
end
