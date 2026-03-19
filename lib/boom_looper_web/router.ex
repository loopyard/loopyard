defmodule BoomLooperWeb.Router do
  use BoomLooperWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BoomLooperWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BoomLooperWeb.Plugs.BasicAuth
  end

  scope "/", BoomLooperWeb do
    pipe_through :browser

    live "/", WorkspaceLive, :index
    live "/w/:workspace_id", ChatLive, :index
    live "/w/:workspace_id/new", ChatLive, :new
    live "/w/:workspace_id/chat/:id", ChatLive, :chat
    live "/w/:workspace_id/chat/:id/container", ChatLive, :container
    live "/w/:workspace_id/services", ChatLive, :services
    live "/w/:workspace_id/service/:service_name", ChatLive, :service
    live "/system", SystemLive, :index

    get "/w/:workspace_id/chat/:id/msg/:index", OutputController, :show
  end
end
