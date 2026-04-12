defmodule BoomLooper.SourceTest do
  use ExUnit.Case, async: true

  alias BoomLooper.Source

  describe "for_project/1" do
    test "dispatches :local → Source.Local" do
      assert Source.for_project(%{source_type: :local}) == BoomLooper.Source.Local
    end

    test "dispatches :github → Source.GitHub" do
      assert Source.for_project(%{source_type: :github}) == BoomLooper.Source.GitHub
    end

    test "falls back to GitHub when only git_url is set (legacy record)" do
      assert Source.for_project(%{git_url: "git@github.com:acme/thing.git"}) ==
               BoomLooper.Source.GitHub
    end

    test "defaults to Local when nothing identifies the source" do
      assert Source.for_project(%{}) == BoomLooper.Source.Local
    end
  end

  describe "supports_git?/1" do
    test "returns true for Source.Local" do
      assert Source.supports_git?(BoomLooper.Source.Local)
    end

    test "returns true for Source.GitHub (stubs exist)" do
      assert Source.supports_git?(BoomLooper.Source.GitHub)
    end
  end
end
