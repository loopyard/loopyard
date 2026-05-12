defmodule Loopyard.SourceTest do
  use ExUnit.Case, async: true

  alias Loopyard.Source

  describe "for_project/1" do
    test "dispatches :local → Source.Local" do
      assert Source.for_project(%{source_type: :local}) == Loopyard.Source.Local
    end

    test "dispatches :github → Source.GitHub" do
      assert Source.for_project(%{source_type: :github}) == Loopyard.Source.GitHub
    end

    test "falls back to GitHub when only git_url is set (legacy record)" do
      assert Source.for_project(%{git_url: "git@github.com:acme/thing.git"}) ==
               Loopyard.Source.GitHub
    end

    test "defaults to Local when nothing identifies the source" do
      assert Source.for_project(%{}) == Loopyard.Source.Local
    end
  end

  describe "supports_git?/1" do
    test "returns true for Source.Local" do
      assert Source.supports_git?(Loopyard.Source.Local)
    end

    test "GitHub git stubs return :not_implemented" do
      # GitHub adapter exports git functions but they return :not_implemented
      assert {:error, :not_implemented} = Loopyard.Source.GitHub.git_log(nil, nil, [])
      assert {:error, :not_implemented} = Loopyard.Source.GitHub.git_status(nil, nil)
      assert {:error, :not_implemented} = Loopyard.Source.GitHub.git_diff(nil, nil, [])
      assert {:error, :not_implemented} = Loopyard.Source.GitHub.git_show(nil, nil, "HEAD", "f")
    end
  end
end
