defmodule LoopyardWeb.MCP.Listener do
  @moduledoc """
  Dedicated HTTP listener for the ACP MCP bridge — a **separate** Bandit
  endpoint from `LoopyardWeb.Endpoint`, on its own port bound to `0.0.0.0`.

  Why its own listener instead of a route on the main endpoint: the main
  endpoint binds `127.0.0.1` by default (the whole UI stays off the network
  until an operator deliberately exposes it). But an in-container ACP harness
  reaches the host via `host.docker.internal`, which a loopback bind refuses.
  Rather than force the entire web UI onto `0.0.0.0` just so containers can call
  back, we expose ONLY this narrow, bearer-authed tool bridge. The attack
  surface reachable from the network is exactly one thing: token-gated MCP tool
  calls (`LoopyardWeb.MCP.Server`), each scoped to a single agent's workspace.

  A minimal pipeline — JSON body parsing, then the server plug. No session, no
  CSRF (there's no browser here), no Phoenix router.

  Config (`config :loopyard, :acp_mcp_listener, ...`):
    * `enabled` — start the listener at all (default true; false in test).
    * `port` — TCP port (default 4030; `LOOPYARD_MCP_PORT` overrides).
    * `ip` — bind address (default `{0, 0, 0, 0}` so containers can reach it).
  """
  use Plug.Builder

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug LoopyardWeb.MCP.Server

  @default_port 4030

  @doc "Child spec for the supervision tree, or nil when disabled."
  def child_spec_or_nil do
    cfg = Application.get_env(:loopyard, :acp_mcp_listener, [])

    if Keyword.get(cfg, :enabled, true) do
      {Bandit,
       plug: __MODULE__,
       scheme: :http,
       ip: Keyword.get(cfg, :ip, {0, 0, 0, 0}),
       port: port(),
       startup_log: false}
    end
  end

  @doc "The port the MCP bridge listens on (env > config > default)."
  def port do
    with nil <- env_port(),
         nil <- Application.get_env(:loopyard, :acp_mcp_listener, [])[:port] do
      @default_port
    end
  end

  defp env_port do
    case System.get_env("LOOPYARD_MCP_PORT") do
      nil -> nil
      "" -> nil
      s -> String.to_integer(s)
    end
  end
end
