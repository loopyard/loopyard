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

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Tidewave
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
