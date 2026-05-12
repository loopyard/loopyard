defmodule Loopyard.ToolTest do
  use ExUnit.Case

  defmodule SampleTool do
    use Loopyard.Tool,
      name: "sample",
      description: "A sample tool for testing.",
      params: [
        name: {:string, required: true, description: "The name"},
        count: {:integer, required: true},
        verbose: :boolean,
        tags: :list
      ]

    def execute(%{name: name, count: count} = params, _assigns) do
      verbose = Map.get(params, :verbose, false)
      result = if verbose, do: "#{name} x#{count} (verbose)", else: "#{name} x#{count}"
      {:ok, result}
    end
  end

  describe "use Loopyard.Tool" do
    test "generates __tool_name__/0" do
      assert SampleTool.__tool_name__() == "sample"
    end

    test "generates __description__/0" do
      assert SampleTool.__description__() == "A sample tool for testing."
    end

    test "generates input_schema/0 with correct structure" do
      schema = SampleTool.input_schema()
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
      assert is_list(schema["required"])
    end

    test "schema has correct property types" do
      props = SampleTool.input_schema()["properties"]
      assert props["name"]["type"] == "string"
      assert props["count"]["type"] == "integer"
      assert props["verbose"]["type"] == "boolean"
      assert props["tags"]["type"] == "array"
    end

    test "schema includes descriptions" do
      props = SampleTool.input_schema()["properties"]
      assert props["name"]["description"] == "The name"
    end

    test "schema marks required fields" do
      required = SampleTool.input_schema()["required"]
      assert "name" in required
      assert "count" in required
      refute "verbose" in required
      refute "tags" in required
    end

    test "execute/2 works" do
      assert {:ok, "hello x3"} = SampleTool.execute(%{name: "hello", count: 3}, %{})

      assert {:ok, "hello x3 (verbose)"} =
               SampleTool.execute(%{name: "hello", count: 3, verbose: true}, %{})
    end
  end

  defmodule MinimalTool do
    use Loopyard.Tool,
      name: "minimal",
      description: "No params."

    def execute(_params, _assigns), do: {:ok, "done"}
  end

  describe "tool with no params" do
    test "generates empty schema" do
      schema = MinimalTool.input_schema()
      assert schema["properties"] == %{}
      assert schema["required"] == []
    end

    test "execute works" do
      assert {:ok, "done"} = MinimalTool.execute(%{}, %{})
    end
  end
end
