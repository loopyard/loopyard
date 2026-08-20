defmodule Loopyard.Harness.ACP.Connection.ModelsTest do
  @moduledoc """
  Model-list normalization across adapter dialects. Both shapes reach the same
  sidebar row, so a label that's right for one vendor and a paragraph for
  another is a real bug, not cosmetics.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Harness.ACP.Connection.Models

  describe "model_name/2" do
    test "claude-agent-acp: the description's leading segment beats the CLI alias" do
      # This adapter names entries by alias ("opus") and hides the marketing
      # name in the description.
      models = [
        %{"modelId" => "opus", "name" => "opus", "description" => "Opus 4.6 · most capable"}
      ]

      assert Models.model_name(models, "opus") == "Opus 4.6"
    end

    test "codex-acp: a plain-sentence description does NOT become the label" do
      # Observed live: taking the leading segment of "Latest frontier agentic
      # coding model." put the whole sentence where the model name goes.
      models = [
        %{
          "modelId" => "gpt-5.6-sol",
          "name" => "GPT-5.6-Sol",
          "description" => "Latest frontier agentic coding model."
        }
      ]

      assert Models.model_name(models, "gpt-5.6-sol") == "GPT-5.6-Sol"
    end

    test "falls back to the description when there is no name" do
      models = [%{"modelId" => "m1", "description" => "Some Model"}]
      assert Models.model_name(models, "m1") == "Some Model"
    end

    test "falls back to the name when there is no description" do
      models = [%{"modelId" => "m1", "name" => "Some Model"}]
      assert Models.model_name(models, "m1") == "Some Model"
    end

    test "unknown id and malformed input yield nil rather than raising" do
      assert Models.model_name([%{"modelId" => "m1", "name" => "M"}], "nope") == nil
      assert Models.model_name([], "m1") == nil
      assert Models.model_name(nil, "m1") == nil
      assert Models.model_name([%{"modelId" => "m1"}], "m1") == nil
    end
  end

  describe "extract_models/1 dialects" do
    test "config_option dialect (claude-agent-acp 0.60+)" do
      result = %{
        "configOptions" => [
          %{
            "id" => "model",
            "currentValue" => "sonnet",
            "options" => [
              %{"value" => "sonnet", "name" => "Sonnet", "description" => "Sonnet 4.5 · balanced"}
            ]
          }
        ]
      }

      assert {[%{"modelId" => "sonnet"}], "sonnet", :config_option} =
               Models.extract_models(result)
    end

    test "legacy models dialect (what codex-acp reports)" do
      result = %{
        "models" => %{
          "availableModels" => [%{"modelId" => "gpt-5.6-sol", "name" => "GPT-5.6-Sol"}],
          "currentModelId" => "gpt-5.6-sol"
        }
      }

      assert {[%{"modelId" => "gpt-5.6-sol"}], "gpt-5.6-sol", :set_model} =
               Models.extract_models(result)
    end
  end
end
