defmodule Loopyard.RegistryHelperTest do
  use ExUnit.Case

  alias Loopyard.RegistryHelper

  # Use the ChatAgentRegistry since it already exists
  @registry Loopyard.ChatAgentRegistry

  describe "whereis/2" do
    test "returns :error for unregistered key" do
      assert :error = RegistryHelper.whereis(@registry, "nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "call/4" do
    test "returns {:error, :not_found} for unregistered key" do
      assert {:error, :not_found} = RegistryHelper.call(@registry, "nonexistent", :get_state)
    end
  end

  describe "cast/3" do
    test "returns :ok even for unregistered key" do
      assert :ok = RegistryHelper.cast(@registry, "nonexistent", :some_message)
    end
  end
end
