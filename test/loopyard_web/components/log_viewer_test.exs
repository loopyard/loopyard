defmodule LoopyardWeb.Components.LogViewerTest do
  use ExUnit.Case

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import LoopyardWeb.Components.LogViewer

  defp render_comp(func, assigns_map) do
    rendered_to_string(func.(Map.new(assigns_map) |> Map.put(:__changed__, %{})))
  end

  describe "log_panel/1" do
    test "renders a pre element with TailScroll hook" do
      html = render_comp(&log_panel/1, %{id: "test-log", content: "hello world", class: ""})
      assert html =~ "phx-hook=\"TailScroll\""
      assert html =~ "id=\"test-log\""
      assert html =~ "hello world"
    end

    test "includes custom CSS classes" do
      html = render_comp(&log_panel/1, %{id: "log", content: "text", class: "extra-class"})
      assert html =~ "extra-class"
    end

    test "renders empty content" do
      html = render_comp(&log_panel/1, %{id: "log", content: "", class: ""})
      assert html =~ "id=\"log\""
    end
  end

  describe "log_inline/1" do
    test "renders building status with animated dot" do
      html =
        render_comp(&log_inline/1, %{
          content: "Building...",
          status: :building,
          title: nil,
          raw_url: nil,
          max_lines: 50
        })

      assert html =~ "animate-pulse"
      assert html =~ "Running..."
      assert html =~ "Building..."
    end

    test "renders done status with green dot" do
      html =
        render_comp(&log_inline/1, %{
          content: "Done!",
          status: :done,
          title: "npm install",
          raw_url: nil,
          max_lines: 50
        })

      assert html =~ "bg-green-500"
      assert html =~ "npm install — done"
    end

    test "renders failed status with red dot" do
      html =
        render_comp(&log_inline/1, %{
          content: "Error!",
          status: :failed,
          title: nil,
          raw_url: nil,
          max_lines: 50
        })

      assert html =~ "bg-red-500"
      assert html =~ "Command — failed"
    end

    test "truncates long output and shows indicator" do
      long_content = Enum.map(1..100, fn i -> "Line #{i}" end) |> Enum.join("\n")

      html =
        render_comp(&log_inline/1, %{
          content: long_content,
          status: :done,
          title: nil,
          raw_url: nil,
          max_lines: 50
        })

      assert html =~ "truncated"
      assert html =~ "Line 100"
    end

    test "shows raw_url link when provided" do
      html =
        render_comp(&log_inline/1, %{
          content: "output",
          status: :done,
          title: nil,
          raw_url: "/messages/agent123/msg456/raw",
          max_lines: 50
        })

      assert html =~ "open"
      assert html =~ "/messages/agent123/msg456/raw"
    end

    test "does not show raw_url link when nil" do
      html =
        render_comp(&log_inline/1, %{
          content: "output",
          status: :done,
          title: nil,
          raw_url: nil,
          max_lines: 50
        })

      refute html =~ ">open<"
    end
  end

  describe "log_multi_service/1" do
    test "renders service logs with colored prefixes" do
      logs = [
        %{name: "postgres", logs: "pg started\npg ready"},
        %{name: "redis", logs: "redis started"}
      ]

      html = render_comp(&log_multi_service/1, %{logs: logs})
      assert html =~ "postgres"
      assert html =~ "redis"
      assert html =~ "pg started"
      assert html =~ "redis started"
    end

    test "renders empty logs" do
      html = render_comp(&log_multi_service/1, %{logs: []})
      assert html =~ "bg-zinc-950"
    end
  end
end
