defmodule LoopyardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :loopyard

  @session_options [
    store: :cookie,
    key: "_loopyard_key",
    signing_salt: "loopyard_sign",
    same_site: "Lax"
  ]

  socket "/terminal", LoopyardWeb.UserSocket, websocket: true

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :loopyard,
    gzip: false,
    only: LoopyardWeb.static_paths()

  # Chime WAVs ship from the `:aural` package's priv dir (regenerated
  # at boot by Aural.ChimeAssets). The package's own Plug.Static would
  # be nice, but Phoenix endpoints don't compose plugs from deps — so
  # the host mounts the dep's priv directory directly.
  plug Plug.Static,
    at: "/chimes",
    from: {:aural, "priv/static/chimes"},
    gzip: false

  # Tidewave must run BEFORE Plug.Parsers so it can read the raw
  # request body for MCP messages. Dev-only — `code_reloading?` is
  # the standard gate for "this is a dev environment."
  if code_reloading? do
    plug Tidewave

    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LoopyardWeb.Router
end
