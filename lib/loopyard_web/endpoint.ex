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

  # In dev, force the browser to REVALIDATE non-digested assets (app.css/app.js)
  # against their etag on every load instead of heuristically serving a cached
  # copy. Without this, `cache-control: public` (no max-age / last-modified) lets
  # mobile browsers keep a stale copy — so a hot-rebuilt CSS/JS never arrives and
  # a refresh "does nothing". Prod keeps the default (assets are digested +
  # immutable there).
  @static_cache_control if Mix.env() == :prod, do: "public", else: "no-cache"

  plug Plug.Static,
    at: "/",
    from: :loopyard,
    gzip: false,
    cache_control_for_etags: @static_cache_control,
    only: LoopyardWeb.static_paths()

  # Chimes used to ship as static WAVs served from {:aural,
  # "priv/static/chimes"}. They're mixed into the bed stream
  # server-side now (single ffmpeg encoder, harmonic integration),
  # so the dedicated /chimes mount is gone.

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
