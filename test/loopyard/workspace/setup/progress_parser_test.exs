defmodule Loopyard.Workspace.Setup.ProgressParserTest do
  use ExUnit.Case, async: true

  alias Loopyard.Workspace.Setup.ProgressParser

  describe "parse_rsync_line/1" do
    test "parses a typical progress2 line with xfr block" do
      line = "      1,234,567,890  87%   12.34MB/s    0:00:23 (xfr#4231, to-chk=89/15000)"
      payload = ProgressParser.parse_rsync_line(line)

      assert payload.bytes == 1_234_567_890
      assert payload.percent == 87
      assert payload.rate_bps == 12_340_000
      assert payload.eta_seconds == 23
      assert payload.files_done == 4231
      assert payload.files_total == 15000
    end

    test "parses progress2 line without xfr block" do
      line = "        524,288  12%   2.50MB/s    0:00:42"
      payload = ProgressParser.parse_rsync_line(line)

      assert payload.percent == 12
      assert payload.rate_bps == 2_500_000
      refute Map.has_key?(payload, :files_done)
    end

    test "parses an MM:SS ETA" do
      line = "100  10%   1.00MB/s    1:30"
      payload = ProgressParser.parse_rsync_line(line)
      assert payload.eta_seconds == 90
    end

    test "treats a bare path as current_file" do
      assert ProgressParser.parse_rsync_line("app/controllers/users_controller.rb") ==
               %{current_file: "app/controllers/users_controller.rb"}
    end

    test "ignores rsync banner lines" do
      assert ProgressParser.parse_rsync_line("sending incremental file list") == nil
      assert ProgressParser.parse_rsync_line("total size is 12345") == nil
    end

    test "ignores blank lines" do
      assert ProgressParser.parse_rsync_line("") == nil
      assert ProgressParser.parse_rsync_line("   ") == nil
    end

    test "handles KB/s rate units" do
      line = "1024 50% 256.0KB/s 0:00:01"
      payload = ProgressParser.parse_rsync_line(line)
      assert payload.rate_bps == 256_000
    end
  end

  describe "parse_rsync_chunk/1" do
    test "merges multiple lines, current_file wins" do
      chunk = """
      app/controllers/foo.rb
      app/controllers/bar.rb
      1,000  10%   1.00MB/s    0:00:10
      """

      payload = ProgressParser.parse_rsync_chunk(chunk)

      assert payload.percent == 10
      assert payload.current_file == "app/controllers/bar.rb"
    end

    test "returns nil for chunks with no useful info" do
      chunk = """
      sending incremental file list

      """

      assert ProgressParser.parse_rsync_chunk(chunk) == nil
    end

    test "returns just current_file when no progress line" do
      chunk = "lib/foo.ex\n"
      assert ProgressParser.parse_rsync_chunk(chunk) == %{current_file: "lib/foo.ex"}
    end
  end
end
