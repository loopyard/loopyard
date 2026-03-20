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

    live "/", ProjectListLive, :index
    live "/p/:project_id", ProjectLive, :index
    live "/p/:project_id/b/:branch_id", ChatLive, :index
    live "/p/:project_id/b/:branch_id/new", ChatLive, :new
    live "/p/:project_id/b/:branch_id/chat/:id", ChatLive, :chat
    live "/p/:project_id/b/:branch_id/chat/:id/container", ChatLive, :container
    live "/p/:project_id/b/:branch_id/services", ChatLive, :services
    live "/p/:project_id/b/:branch_id/service/:service_name", ChatLive, :service
    live "/p/:project_id/b/:branch_id/service/:service_name/console", ChatLive, :console

    live "/system", SystemLive, :index

    live "/p/:project_id/b/:branch_id/chat/:id/msg/:index", MessageLive, :show
    get "/p/:project_id/b/:branch_id/chat/:id/msg/:index/raw", OutputController, :show
    get "/launch/:secret", LaunchController, :launch
    get "/debug", DebugController, :index
  end
end
