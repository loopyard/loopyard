defmodule BoomLooper.SecretsTest do
  use ExUnit.Case

  alias BoomLooper.Secrets

  @test_storage_dir Path.join(System.tmp_dir!(), "boom-looper-secrets-test-#{:rand.uniform(100_000)}")

  setup do
    # Override storage path for tests by writing directly to a temp file
    File.mkdir_p!(@test_storage_dir)

    on_exit(fn ->
      File.rm_rf!(@test_storage_dir)
    end)

    # Patch the module to use test path by manipulating the file directly
    # Since Secrets uses a compile-time constant, we test via the real path
    # but clean up after. For isolation, we'll use the real API but clean up.
    :ok
  end

  describe "storage_path/0" do
    test "returns path under ~/.boomlooper" do
      path = Secrets.storage_path()
      assert String.ends_with?(path, ".boomlooper/secrets.json")
      assert String.starts_with?(path, System.user_home!())
    end
  end

  describe "CRUD operations" do
    setup do
      # Clean up any existing test secrets
      for key <- ["test_key", "test_key2", "another_key"] do
        Secrets.delete(key)
      end

      on_exit(fn ->
        for key <- ["test_key", "test_key2", "another_key"] do
          Secrets.delete(key)
        end
      end)

      :ok
    end

    test "put and get a secret" do
      assert :ok = Secrets.put("test_key", "Test Secret", "secret_value_123")
      assert {:ok, "secret_value_123"} = Secrets.get("test_key")
    end

    test "get returns :not_found for missing key" do
      assert :not_found = Secrets.get("nonexistent_key_xyz")
    end

    test "list returns keys and names without values" do
      Secrets.put("test_key", "My Token", "value1")
      Secrets.put("test_key2", "API Key", "value2")

      secrets = Secrets.list()
      keys = Enum.map(secrets, & &1.key)

      assert "test_key" in keys
      assert "test_key2" in keys

      # Ensure values are NOT exposed in list
      refute Enum.any?(secrets, fn s -> Map.has_key?(s, :value) end)

      # Check names are correct
      test_secret = Enum.find(secrets, &(&1.key == "test_key"))
      assert test_secret.name == "My Token"
    end

    test "delete removes a secret" do
      Secrets.put("test_key", "To Delete", "delete_me")
      assert {:ok, "delete_me"} = Secrets.get("test_key")

      Secrets.delete("test_key")
      assert :not_found = Secrets.get("test_key")
    end

    test "put overwrites existing secret" do
      Secrets.put("test_key", "Original", "original_value")
      Secrets.put("test_key", "Updated", "updated_value")

      assert {:ok, "updated_value"} = Secrets.get("test_key")

      test_secret = Enum.find(Secrets.list(), &(&1.key == "test_key"))
      assert test_secret.name == "Updated"
    end

    test "delete non-existent key is a no-op" do
      assert :ok = Secrets.delete("totally_nonexistent_key")
    end
  end
end
