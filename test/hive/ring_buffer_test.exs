defmodule Hive.RingBufferTest do
  use ExUnit.Case, async: true

  alias Hive.RingBuffer

  describe "new/1" do
    test "creates an empty buffer with default max" do
      buf = RingBuffer.new()
      assert RingBuffer.to_binary(buf) == ""
      assert RingBuffer.byte_size_total(buf) == 0
    end

    test "creates an empty buffer with custom max" do
      buf = RingBuffer.new(1024)
      assert buf.max_bytes == 1024
    end
  end

  describe "append/2" do
    test "appends data to the buffer" do
      buf = RingBuffer.new() |> RingBuffer.append("hello") |> RingBuffer.append(" world")
      assert RingBuffer.to_binary(buf) == "hello world"
      assert RingBuffer.byte_size_total(buf) == 11
    end

    test "trims old data when over max size" do
      buf = RingBuffer.new(10)
      buf = buf |> RingBuffer.append("aaaaa") |> RingBuffer.append("bbbbb") |> RingBuffer.append("ccccc")

      result = RingBuffer.to_binary(buf)
      # Should have dropped "aaaaa" to stay under 10 bytes
      assert byte_size(result) <= 10
      assert String.contains?(result, "ccccc")
      refute String.contains?(result, "aaaaa")
    end

    test "handles exact boundary" do
      buf = RingBuffer.new(10)
      buf = buf |> RingBuffer.append("12345") |> RingBuffer.append("67890")

      assert RingBuffer.to_binary(buf) == "1234567890"
      assert RingBuffer.byte_size_total(buf) == 10
    end

    test "handles single chunk larger than max" do
      buf = RingBuffer.new(5)
      buf = RingBuffer.append(buf, "abcdefghij")

      # The chunk is 10 bytes but max is 5, so it gets trimmed
      # Since the chunk is a single unit, it gets dropped entirely
      assert RingBuffer.byte_size_total(buf) == 0
    end

    test "handles empty data" do
      buf = RingBuffer.new()
      buf = RingBuffer.append(buf, "")
      assert RingBuffer.to_binary(buf) == ""
    end

    test "handles binary data with special characters" do
      buf = RingBuffer.new()
      ansi = "\e[31mred text\e[0m"
      buf = RingBuffer.append(buf, ansi)
      assert RingBuffer.to_binary(buf) == ansi
    end
  end

  describe "to_binary/1" do
    test "preserves order of chunks" do
      buf =
        RingBuffer.new()
        |> RingBuffer.append("first ")
        |> RingBuffer.append("second ")
        |> RingBuffer.append("third")

      assert RingBuffer.to_binary(buf) == "first second third"
    end
  end

  describe "byte_size_total/1" do
    test "tracks total bytes accurately" do
      buf =
        RingBuffer.new()
        |> RingBuffer.append("abc")
        |> RingBuffer.append("de")

      assert RingBuffer.byte_size_total(buf) == 5
    end

    test "tracks bytes after trimming" do
      buf =
        RingBuffer.new(6)
        |> RingBuffer.append("aaa")
        |> RingBuffer.append("bbb")
        |> RingBuffer.append("ccc")

      assert RingBuffer.byte_size_total(buf) <= 6
    end
  end
end
