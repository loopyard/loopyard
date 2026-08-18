defmodule Loopyard.MCP.Token do
  @moduledoc """
  Per-agent scoped bearer tokens for the ACP MCP bridge
  (`LoopyardWeb.MCP.Server`).

  An in-container ACP harness can't use the in-process Elixir MCP servers the
  ClaudeCode backend uses — it reaches Loopyard's control-plane tools over HTTP
  instead. This token is what binds one of those HTTP sessions to a single
  agent's identity: the container presents `Authorization: Bearer <token>`, the
  plug verifies it, and every tool call runs as `{agent_id, workspace_id}` —
  never a caller-supplied id.

  ## Signing key (issue #75)

  Tokens are signed with a PER-INSTALL random secret (`signing_secret/0`),
  persisted at `<LOOPYARD_HOME>/mcp_token_secret` and generated on first use.
  They are NOT signed with `LoopyardWeb.Endpoint`'s `secret_key_base`, because
  in dev/`mix loopyard.server` that secret is a git-committed constant — anyone
  with the public repo could forge a token and drive the bridge. The signing
  secret never leaves the host; the token only ever lives inside a container.

  ## Revocation (issue #81)

  The token embeds the agent's revocation `epoch` at mint time. `verify/1`
  rejects a token whose epoch is below the agent's current epoch, and `revoke/1`
  (called on agent teardown and workspace deletion) bumps it — so a leaked
  token stops working when its agent/workspace goes away, instead of staying
  valid for weeks. Epochs live in ETS and clear on restart, which is safe: a
  restart tears down every agent and container, and a shortened `max_age` bounds
  a token's life regardless.

  This is the network edge of the workspace-agent sandbox boundary. Keep the
  claims minimal and NEVER widen the scope encoded here — see docs/SECURITY.md.
  """

  @salt "acp mcp bearer v2"
  # Bound a token's life even if revocation state is lost (e.g. a restart clears
  # the epoch table). A week comfortably covers a long-lived, idle-reaped,
  # resumed agent while capping the blast radius of a leak.
  @max_age_seconds 60 * 60 * 24 * 7

  @secret_file "mcp_token_secret"
  @pt_key {__MODULE__, :signing_secret}
  @epoch_table :mcp_token_epochs

  @doc """
  Sign a token binding this MCP session to one agent. `scope` selects which
  toolset the bridge serves: `:workspace` (the default — container/service
  control-plane tools, scoped to `workspace_id`) or `:operator` (the operator's
  project/identity control-plane tools; `workspace_id` is nil). Returns the
  opaque token string.
  """
  def sign(agent_id, workspace_id, scope \\ :workspace)
      when is_binary(agent_id) and (is_binary(workspace_id) or is_nil(workspace_id)) and
             scope in [:workspace, :operator] do
    Phoenix.Token.sign(signing_secret(), @salt, %{
      agent_id: agent_id,
      workspace_id: workspace_id,
      scope: scope,
      epoch: current_epoch(agent_id)
    })
  end

  @doc """
  Verify a bearer token. Returns `{:ok, %{agent_id:, workspace_id:, scope:}}` or
  `{:error, :invalid | :expired | :missing}`.
  """
  def verify(token) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(signing_secret(), @salt, token, max_age: @max_age_seconds) do
      {:ok, %{agent_id: agent_id} = claims} when is_binary(agent_id) ->
        cond do
          claims[:scope] not in [:workspace, :operator] ->
            {:error, :invalid}

          # A token minted before the agent's current epoch has been revoked.
          (claims[:epoch] || 0) < current_epoch(agent_id) ->
            {:error, :invalid}

          true ->
            {:ok,
             %{agent_id: agent_id, workspace_id: claims[:workspace_id], scope: claims[:scope]}}
        end

      {:ok, _malformed} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_), do: {:error, :missing}

  @doc """
  Revoke every outstanding token for `agent_id` by bumping its epoch. Called on
  agent teardown and workspace deletion. Best-effort: if the ETS table isn't up
  (very early boot) it no-ops.
  """
  def revoke(agent_id) when is_binary(agent_id) do
    :ets.update_counter(@epoch_table, agent_id, {2, 1}, {agent_id, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp current_epoch(agent_id) do
    case :ets.lookup(@epoch_table, agent_id) do
      [{^agent_id, epoch}] -> epoch
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  # A per-install random secret, cached in persistent_term and persisted to
  # <LOOPYARD_HOME>/mcp_token_secret so it survives restarts (a resumed agent's
  # token must still verify). Generated on first use with 0600 perms.
  defp signing_secret do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        secret = read_or_create_secret()
        :persistent_term.put(@pt_key, secret)
        secret

      secret ->
        secret
    end
  end

  defp read_or_create_secret do
    path = Path.join(loopyard_home(), @secret_file)

    case File.read(path) do
      {:ok, secret} when byte_size(secret) >= 64 ->
        secret

      _ ->
        secret = 64 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, secret)
        _ = File.chmod(path, 0o600)
        secret
    end
  end

  defp loopyard_home do
    System.get_env("LOOPYARD_HOME", Path.expand("~/.loopyard"))
  end
end
