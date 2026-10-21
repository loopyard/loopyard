defmodule Loopyard.Harness.ACP.Connection.ModesTest do
  @moduledoc """
  Session-mode normalization across the two wire shapes. The composer's
  Discuss switch renders off `plan_mode_id/1`, so a dialect that parses empty
  silently hides the control for that harness.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP.Connection.Modes

  describe "extract_modes/1" do
    test "the spec'd `modes` map wins (claude-agent-acp sends both)" do
      result = %{
        "modes" => %{
          "currentModeId" => "default",
          "availableModes" => [
            %{"id" => "default", "name" => "Manual", "description" => "Always ask"},
            %{"id" => "plan", "name" => "Plan", "description" => "Create a plan"}
          ]
        },
        "configOptions" => [
          %{
            "id" => "mode",
            "category" => "mode",
            "currentValue" => "default",
            "options" => [%{"value" => "default", "name" => "Manual"}]
          }
        ]
      }

      assert {[%{"id" => "default"}, %{"id" => "plan", "name" => "Plan"}], "default", :set_mode} =
               Modes.extract_modes(result)
    end

    test "config-option dialect when there is no `modes` map" do
      result = %{
        "configOptions" => [
          %{"id" => "model", "currentValue" => "opus", "options" => []},
          %{
            "id" => "mode",
            "category" => "mode",
            "currentValue" => "plan",
            "options" => [
              %{"value" => "default", "name" => "Manual", "description" => "Ask"},
              %{"value" => "plan", "name" => "Plan", "description" => "Plan first"}
            ]
          }
        ]
      }

      assert {[%{"id" => "default"}, %{"id" => "plan"}], "plan", :config_option} =
               Modes.extract_modes(result)
    end

    test "absent, empty and malformed inputs yield no modes rather than raising" do
      assert {[], nil, :set_mode} = Modes.extract_modes(%{})
      assert {[], nil, :set_mode} = Modes.extract_modes(%{"modes" => %{}})
      assert {[], nil, :set_mode} = Modes.extract_modes(%{"modes" => %{"availableModes" => []}})
      assert {[], nil, :set_mode} = Modes.extract_modes(nil)

      # A "mode" option with no options (what the legacy fixture carried) is
      # not a mode list.
      assert {[], nil, :set_mode} =
               Modes.extract_modes(%{
                 "configOptions" => [
                   %{"id" => "mode", "currentValue" => "default", "options" => []}
                 ]
               })
    end
  end

  describe "plan_mode_id/1" do
    test "matches by id, then by a name that says plan" do
      assert Modes.plan_mode_id([%{"id" => "plan", "name" => "Plan"}]) == "plan"
      assert Modes.plan_mode_id([%{"id" => "planning", "name" => "Plan mode"}]) == "planning"
      assert Modes.plan_mode_id([%{"id" => "default", "name" => "Manual"}]) == nil
      assert Modes.plan_mode_id([]) == nil
      assert Modes.plan_mode_id(nil) == nil
    end
  end
end
