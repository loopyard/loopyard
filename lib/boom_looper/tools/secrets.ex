defmodule BoomLooper.Tools.Secrets do
  @moduledoc """
  MCP tool server for secret management.

  Agents request secrets at runtime via these tools rather than having
  them pre-injected into containers as environment variables.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-secrets"

  alias BoomLooper.Secrets

  # --- Public API ---

  def do_list_secrets do
    Secrets.list()
  end

  def do_get_secret(key) do
    case Secrets.get(key) do
      {:ok, value} -> {:ok, %{key: key, value: value}}
      :not_found -> {:error, "Secret '#{key}' not found. Use list_secrets to see available secrets."}
    end
  end

  # --- Tool definitions ---

  tool :list_secrets, "List available secret names and keys (not values). Use this to discover what secrets are available before requesting one." do
    def execute(_params) do
      {:ok, BoomLooper.Tools.Secrets.do_list_secrets()}
    end
  end

  tool :get_secret, "Get a secret value by key. The secret can be used as an env var, CLI argument, config file value, etc." do
    field :key, :string, required: true, description: "The secret key (e.g. 'github_token')"

    def execute(%{key: key}) do
      BoomLooper.Tools.Secrets.do_get_secret(key)
    end
  end
end
