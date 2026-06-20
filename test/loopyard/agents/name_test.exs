defmodule Loopyard.Agents.NameTest do
  use ExUnit.Case, async: true

  alias Loopyard.Agents.Name
  alias Loopyard.Harness

  describe "label_for/1" do
    test "known harnesses map to their brand" do
      assert Name.label_for(Harness.Claude) == "Claude"
      assert Name.label_for(Harness.ACP) == "Claude"
      assert Name.label_for(Harness.Fake) == "Claude"
    end

    test "nil falls back to the default harness" do
      assert Name.label_for(nil) == "Claude"
    end

    test "an unknown harness module uses its last name segment" do
      assert Name.label_for(Some.Future.Backend.Codex) == "Codex"
    end
  end

  describe "dedupe/2" do
    test "returns the base name when nothing is taken" do
      assert Name.dedupe("Claude", []) == "Claude"
    end

    test "a second agent of the same harness gets ' 2'" do
      assert Name.dedupe("Claude", ["Claude"]) == "Claude 2"
    end

    test "fills the lowest free slot, not blindly count+1" do
      assert Name.dedupe("Claude", ["Claude", "Claude 3"]) == "Claude 2"
      assert Name.dedupe("Claude", ["Claude", "Claude 2"]) == "Claude 3"
    end

    test "a renamed-away base frees the bare name again" do
      assert Name.dedupe("Claude", ["Claude 2"]) == "Claude"
    end
  end
end
