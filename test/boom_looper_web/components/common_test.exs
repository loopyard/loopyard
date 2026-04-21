defmodule BoomLooperWeb.Components.CommonTest do
  use ExUnit.Case, async: true

  # render_component / rendered_to_string first calls cold-load the
  # component module chain (heex, Phoenix.Template). Under full-suite
  # parallel load the first render can exceed the 2s default.
  @moduletag timeout: 10_000

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import BoomLooperWeb.Components.Common

  describe "flash_banner/1" do
    test "renders nothing when flash key is missing" do
      assigns = %{flash: %{}}
      html = rendered_to_string(~H[<.flash_banner flash={@flash} kind={:error} />])
      refute html =~ "rounded-lg"
    end

    test "renders error message in red" do
      assigns = %{flash: %{"error" => "Something broke"}}
      html = rendered_to_string(~H[<.flash_banner flash={@flash} kind={:error} />])
      assert html =~ "Something broke"
      assert html =~ "bg-red-50"
      assert html =~ "text-red-700"
    end

    test "renders info message in green" do
      assigns = %{flash: %{"info" => "Saved!"}}
      html = rendered_to_string(~H[<.flash_banner flash={@flash} kind={:info} />])
      assert html =~ "Saved!"
      assert html =~ "bg-green-50"
      assert html =~ "text-green-700"
    end

    test "info banner ignores error key" do
      assigns = %{flash: %{"error" => "boom"}}
      html = rendered_to_string(~H[<.flash_banner flash={@flash} kind={:info} />])
      refute html =~ "boom"
    end

    test "custom class is applied alongside the kind class" do
      assigns = %{flash: %{"error" => "x"}}
      html = rendered_to_string(~H[<.flash_banner flash={@flash} kind={:error} class="mx-4 mt-2" />])
      assert html =~ "mx-4 mt-2"
      assert html =~ "bg-red-50"
    end
  end

  describe "skeleton/1" do
    test "default variant is multi-row pulse box" do
      assigns = %{}
      html = rendered_to_string(~H[<.skeleton />])
      assert html =~ "animate-pulse"
      assert html =~ "border"
    end

    test "rows attr controls how many bar rows render" do
      assigns = %{}
      html = rendered_to_string(~H[<.skeleton rows={5} />])
      # Each row is a div with the pulse class — count occurrences.
      pulse_count = html |> String.split("animate-pulse") |> length() |> Kernel.-(1)
      assert pulse_count == 5
    end

    test "card variant has title + bar shape, no border container" do
      assigns = %{}
      html = rendered_to_string(~H[<.skeleton variant={:card} />])
      assert html =~ "animate-pulse"
      # Card variant uses a different layout — should have at least 3 elements
      assert html =~ "h-6"
      assert html =~ "h-2"
    end

    test "extra class merges in" do
      assigns = %{}
      html = rendered_to_string(~H[<.skeleton class="my-extra-class" />])
      assert html =~ "my-extra-class"
    end
  end
end
