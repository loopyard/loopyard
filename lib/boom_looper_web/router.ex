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

  pipeline :api do
    plug :accepts, ["json", "text"]
  end

  scope "/", BoomLooperWeb do
    pipe_through :browser

    live "/", ProjectListLive, :index
    live "/projects/:project_id", ProjectLive, :index
    live "/projects/:project_id/workspaces/:workspace_id", ChatLive, :index
    live "/projects/:project_id/workspaces/:workspace_id/new", ChatLive, :new
    live "/projects/:project_id/workspaces/:workspace_id/agents/:id", ChatLive, :chat
    live "/projects/:project_id/workspaces/:workspace_id/agents/:id/container", ChatLive, :container
    live "/projects/:project_id/workspaces/:workspace_id/services", ChatLive, :services
    live "/projects/:project_id/workspaces/:workspace_id/services/:service_name", ChatLive, :service
    live "/projects/:project_id/workspaces/:workspace_id/services/:service_name/console", ChatLive, :console

    live "/system", SystemLive, :index
    live "/connect", ConnectLive, :index

    live "/messages/:agent_id/:msg_id", MessageLive, :show
    get "/messages/:agent_id/:msg_id/raw", OutputController, :show

    get "/launch/:secret", LaunchController, :launch
  end

  # No CSRF, curl-friendly system endpoints
  scope "/system", BoomLooperWeb do
    pipe_through :api
    get "/log", SystemController, :log
  end
end
