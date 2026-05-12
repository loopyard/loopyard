defmodule LoopyardWeb.FormatTest do
  use ExUnit.Case, async: true

  alias LoopyardWeb.Format

  describe "shorten_path/1" do
    test "replaces home with ~" do
      home = System.user_home!()
      assert Format.shorten_path(home <> "/projects/foo") == "~/projects/foo"
    end

    test "leaves non-home paths alone" do
      assert Format.shorten_path("/var/log/system.log") == "/var/log/system.log"
    end

    test "returns empty string for nil" do
      assert Format.shorten_path(nil) == ""
    end

    test "returns empty string for non-binary" do
      assert Format.shorten_path(:not_a_path) == ""
      assert Format.shorten_path(42) == ""
    end
  end

  describe "project_location/1" do
    test "uses path when present" do
      home = System.user_home!()
      project = %{path: home <> "/myapp", git_url: nil}
      assert Format.project_location(project) == "~/myapp"
    end

    test "falls back to git_url when no path" do
      project = %{path: nil, git_url: "https://github.com/foo/bar.git"}
      assert Format.project_location(project) == "https://github.com/foo/bar.git"
    end

    test "falls back to name when neither" do
      project = %{path: nil, git_url: nil, name: "fallback"}
      assert Format.project_location(project) == "fallback"
    end

    test "empty string when nothing matches" do
      assert Format.project_location(%{}) == ""
    end
  end

  describe "format_bytes/1" do
    test "B for tiny values" do
      assert Format.format_bytes(0) == "0 B"
      assert Format.format_bytes(512) == "512 B"
      assert Format.format_bytes(1023) == "1023 B"
    end

    test "KB at 1024" do
      assert Format.format_bytes(1024) == "1.0 KB"
      assert Format.format_bytes(1536) == "1.5 KB"
    end

    test "MB at 1MiB" do
      assert Format.format_bytes(1_048_576) == "1.0 MB"
      assert Format.format_bytes(5 * 1_048_576) == "5.0 MB"
    end

    test "GB at 1GiB" do
      assert Format.format_bytes(1_073_741_824) == "1.0 GB"
      assert Format.format_bytes(2 * 1_073_741_824) == "2.0 GB"
    end

    test "rounds floats by truncating to int first" do
      assert Format.format_bytes(2048.7) == "2.0 KB"
    end

    test "? for garbage" do
      assert Format.format_bytes(nil) == "?"
      assert Format.format_bytes("string") == "?"
    end
  end

  describe "format_number/1" do
    test "single digits unchanged" do
      assert Format.format_number(0) == "0"
      assert Format.format_number(7) == "7"
    end

    test "no comma under 1000" do
      assert Format.format_number(999) == "999"
    end

    test "comma at 1000" do
      assert Format.format_number(1_000) == "1,000"
      assert Format.format_number(12_345) == "12,345"
    end

    test "multiple commas" do
      assert Format.format_number(1_234_567) == "1,234,567"
      assert Format.format_number(1_000_000_000) == "1,000,000,000"
    end

    test "stringifies non-integers" do
      assert Format.format_number(3.14) == "3.14"
      assert Format.format_number(:atom) == "atom"
    end
  end

  describe "format_rss/1" do
    test "KB under 1024" do
      assert Format.format_rss(0) == "0 KB"
      assert Format.format_rss(512) == "512 KB"
    end

    test "MB at 1024" do
      assert Format.format_rss(1024) == "1.0 MB"
      assert Format.format_rss(2048) == "2.0 MB"
    end

    test "? for garbage" do
      assert Format.format_rss(nil) == "?"
      assert Format.format_rss("3 GB") == "?"
    end
  end

  describe "mem_bar_pct/1" do
    test "returns rounded percentage" do
      assert Format.mem_bar_pct(%{total: 100, used: 25}) == 25.0
      assert Format.mem_bar_pct(%{total: 100, used: 80}) == 80.0
    end

    test "rounds to one decimal" do
      assert Format.mem_bar_pct(%{total: 3, used: 1}) == 33.3
    end

    test "0 when total is 0" do
      assert Format.mem_bar_pct(%{total: 0, used: 0}) == 0
    end

    test "0 for garbage" do
      assert Format.mem_bar_pct(nil) == 0
      assert Format.mem_bar_pct(%{}) == 0
    end
  end

  describe "load_color/2" do
    test "green when load is below half capacity" do
      assert Format.load_color(0.5, 4) == "text-green-500"
    end

    test "amber between 50% and 80%" do
      assert Format.load_color(2.0, 4) == "text-amber-500"
      assert Format.load_color(3.1, 4) == "text-amber-500"
    end

    test "red at 80%+" do
      assert Format.load_color(3.5, 4) == "text-red-500"
      assert Format.load_color(8.0, 4) == "text-red-500"
    end
  end

  describe "log_level_class/1" do
    test "error is bold red" do
      assert Format.log_level_class(:error) == "text-red-500 font-semibold"
    end

    test "warning is amber" do
      assert Format.log_level_class(:warning) == "text-amber-500"
    end

    test "info is blue" do
      assert Format.log_level_class(:info) == "text-blue-400"
    end

    test "debug is zinc" do
      assert Format.log_level_class(:debug) == "text-zinc-500"
    end

    test "unknown defaults to zinc" do
      assert Format.log_level_class(:something_else) == "text-zinc-400"
    end
  end
end
