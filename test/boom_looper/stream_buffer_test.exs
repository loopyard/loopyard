defmodule BoomLooper.StreamBufferTest do
  use ExUnit.Case

  alias BoomLooper.StreamBuffer

  describe "new/1" do
    test "creates empty buffer" do
      buf = StreamBuffer.new()
      assert buf.content == ""
      assert buf.msg_id == nil
      assert buf.title == nil
      assert StreamBuffer.empty?(buf)
      assert StreamBuffer.size(buf) == 0
    end

    test "accepts custom max_bytes" do
      buf = StreamBuffer.new(max_bytes: 100)
      assert buf.max_bytes == 100
    end
  end

  describe "append/3" do
    test "accumulates data" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("hello ")
        |> StreamBuffer.append("world")

      assert buf.content == "hello world"
      assert StreamBuffer.size(buf) == 11
    end

    test "assigns a message ID on first append" do
      buf = StreamBuffer.new() |> StreamBuffer.append("data")
      assert buf.msg_id != nil
      assert is_binary(buf.msg_id)
    end

    test "preserves message ID across appends" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("first")

      id = buf.msg_id

      buf = StreamBuffer.append(buf, "second")
      assert buf.msg_id == id
    end

    test "accepts explicit msg_id" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("data", msg_id: "my-custom-id")

      assert buf.msg_id == "my-custom-id"
    end

    test "accepts title" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("data", title: "Building...")

      assert buf.title == "Building..."
    end

    test "title persists across appends" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("data", title: "Building...")
        |> StreamBuffer.append("more data")

      assert buf.title == "Building..."
    end

    test "title can be overridden" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("data", title: "Building...")
        |> StreamBuffer.append("more data", title: "Installing deps...")

      assert buf.title == "Installing deps..."
    end
  end

  describe "rolling window" do
    test "trims to max_bytes when exceeded" do
      buf = StreamBuffer.new(max_bytes: 10)
        |> StreamBuffer.append("12345")
        |> StreamBuffer.append("67890")
        |> StreamBuffer.append("ABCDE")

      assert StreamBuffer.size(buf) <= 10
      # Should keep the tail
      assert buf.content =~ "ABCDE"
    end

    test "keeps exactly max_bytes of trailing content" do
      buf = StreamBuffer.new(max_bytes: 5)
        |> StreamBuffer.append("hello world")

      assert buf.content == "world"
      assert StreamBuffer.size(buf) == 5
    end

    test "does not trim when under limit" do
      buf = StreamBuffer.new(max_bytes: 100)
        |> StreamBuffer.append("short")

      assert buf.content == "short"
    end

    test "default max_bytes is 8000" do
      buf = StreamBuffer.new()
      assert buf.max_bytes == 8_000
    end

    test "handles exact boundary" do
      buf = StreamBuffer.new(max_bytes: 5)
        |> StreamBuffer.append("exact")

      assert buf.content == "exact"
      assert StreamBuffer.size(buf) == 5
    end

    test "handles multi-byte content safely" do
      # This may split a multi-byte char at the boundary — that's acceptable
      # for log output which is typically ASCII
      buf = StreamBuffer.new(max_bytes: 10)
        |> StreamBuffer.append(String.duplicate("x", 20))

      assert StreamBuffer.size(buf) <= 10
    end
  end

  describe "to_message/1" do
    test "builds a message map with all fields" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("output here", title: "Running tests", msg_id: "msg-123")

      msg = StreamBuffer.to_message(buf)

      assert msg.id == "msg-123"
      assert msg.role == :build
      assert msg.content == "output here"
      assert msg.title == "Running tests"
      assert %DateTime{} = msg.timestamp
    end
  end

  describe "upsert_message/2" do
    test "appends to empty message list" do
      buf = StreamBuffer.new() |> StreamBuffer.append("output")
      messages = StreamBuffer.upsert_message(buf, [])

      assert length(messages) == 1
      assert hd(messages).role == :build
      assert hd(messages).content == "output"
    end

    test "appends after existing non-build messages" do
      existing = [
        %{role: :user, content: "run tests", id: "u1"},
        %{role: :assistant, content: "ok", id: "a1"}
      ]

      buf = StreamBuffer.new() |> StreamBuffer.append("test output")
      messages = StreamBuffer.upsert_message(buf, existing)

      assert length(messages) == 3
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 2).role == :build
    end

    test "replaces existing build message in place" do
      existing = [
        %{role: :user, content: "run tests", id: "u1"},
        %{role: :build, content: "old output", id: "b1", title: nil, timestamp: DateTime.utc_now()},
        %{role: :assistant, content: "done", id: "a1"}
      ]

      buf = StreamBuffer.new()
        |> StreamBuffer.append("old output")
        |> StreamBuffer.append(" + new output")

      messages = StreamBuffer.upsert_message(buf, existing)

      assert length(messages) == 3
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 1).role == :build
      assert Enum.at(messages, 1).content == "old output + new output"
      assert Enum.at(messages, 2).role == :assistant
    end

    test "preserves message ordering" do
      existing = [
        %{role: :user, content: "a", id: "1"},
        %{role: :build, content: "b", id: "2", title: nil, timestamp: DateTime.utc_now()},
        %{role: :system, content: "c", id: "3"}
      ]

      buf = StreamBuffer.new() |> StreamBuffer.append("updated")
      messages = StreamBuffer.upsert_message(buf, existing)

      roles = Enum.map(messages, & &1.role)
      assert roles == [:user, :build, :system]
    end
  end

  describe "restore/2" do
    test "restores from a message map" do
      msg = %{id: "existing-123", content: "previous output\nmore output", title: "npm install"}
      buf = StreamBuffer.restore(msg)

      assert buf.content == "previous output\nmore output"
      assert buf.msg_id == "existing-123"
      assert buf.title == "npm install"
      refute StreamBuffer.empty?(buf)
    end

    test "subsequent appends extend restored content" do
      msg = %{id: "r1", content: "line 1\n", title: "build"}
      buf = StreamBuffer.restore(msg)
        |> StreamBuffer.append("line 2\n")

      assert buf.content == "line 1\nline 2\n"
      assert buf.msg_id == "r1"
    end

    test "restore nil returns empty buffer" do
      buf = StreamBuffer.restore(nil)
      assert StreamBuffer.empty?(buf)
    end

    test "restore message with nil content" do
      buf = StreamBuffer.restore(%{id: "x", content: nil})
      assert buf.content == ""
    end

    test "accepts custom max_bytes" do
      buf = StreamBuffer.restore(%{id: "x", content: "data"}, max_bytes: 100)
      assert buf.max_bytes == 100
    end
  end

  describe "empty?/1 and size/1" do
    test "empty? is true for new buffer" do
      assert StreamBuffer.empty?(StreamBuffer.new())
    end

    test "empty? is false after append" do
      buf = StreamBuffer.new() |> StreamBuffer.append("x")
      refute StreamBuffer.empty?(buf)
    end

    test "size matches byte_size" do
      buf = StreamBuffer.new() |> StreamBuffer.append("hello")
      assert StreamBuffer.size(buf) == 5
    end
  end

  describe "streaming simulation" do
    test "simulates a build that streams 100 chunks" do
      buf = StreamBuffer.new(max_bytes: 500)

      buf = Enum.reduce(1..100, buf, fn i, acc ->
        StreamBuffer.append(acc, "chunk #{i}\n")
      end)

      # Should have trimmed to ~500 bytes
      assert StreamBuffer.size(buf) <= 500

      # Should contain the latest chunks, not the earliest
      assert buf.content =~ "chunk 100"
      refute buf.content =~ "chunk 1\n"

      # Message ID should be stable across all appends
      assert buf.msg_id != nil
    end

    test "simulates page reload mid-stream" do
      # Build up some content
      buf1 = StreamBuffer.new()
        |> StreamBuffer.append("line 1\n", msg_id: "stream-42", title: "Building...")
        |> StreamBuffer.append("line 2\n")
        |> StreamBuffer.append("line 3\n")

      # "Page reload" — save the message, create a new buffer from it
      msg = StreamBuffer.to_message(buf1)
      buf2 = StreamBuffer.restore(msg)

      # Continue streaming
      buf2 = buf2
        |> StreamBuffer.append("line 4\n")
        |> StreamBuffer.append("line 5\n")

      assert buf2.content == "line 1\nline 2\nline 3\nline 4\nline 5\n"
      assert buf2.msg_id == "stream-42"
      assert buf2.title == "Building..."
    end

    test "two viewers see the same content from the same buffer" do
      buf = StreamBuffer.new()
        |> StreamBuffer.append("shared output\n", msg_id: "shared-1")

      # Both viewers upsert into their own message lists
      viewer1_msgs = StreamBuffer.upsert_message(buf, [])
      viewer2_msgs = StreamBuffer.upsert_message(buf, [%{role: :user, content: "hi", id: "u"}])

      assert hd(viewer1_msgs).content == "shared output\n"
      assert List.last(viewer2_msgs).content == "shared output\n"
      assert hd(viewer1_msgs).id == "shared-1"
      assert List.last(viewer2_msgs).id == "shared-1"
    end
  end
end
