defmodule HiveWeb.Router do
  use HiveWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HiveWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug HiveWeb.Plugs.BasicAuth
  end

  scope "/", HiveWeb do
    pipe_through :browser

    live "/", ChatLive, :index
    live "/chat/:id", ChatLive, :show
    live "/terminal", DashboardLive, :index
  end
end
