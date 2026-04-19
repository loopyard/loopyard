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
    live "/projects/:project_id/workspaces/:workspace_id", WorkspaceLive, :index
    live "/projects/:project_id/workspaces/:workspace_id/new", WorkspaceLive, :new
    live "/projects/:project_id/workspaces/:workspace_id/agents/:id", WorkspaceLive, :chat
    live "/projects/:project_id/workspaces/:workspace_id/agents/:id/container", WorkspaceLive, :container
    live "/projects/:project_id/workspaces/:workspace_id/agents/:id/context", WorkspaceLive, :context_panel
    live "/projects/:project_id/workspaces/:workspace_id/services", WorkspaceLive, :services
    live "/projects/:project_id/workspaces/:workspace_id/services/:service_name", WorkspaceLive, :service
    live "/projects/:project_id/workspaces/:workspace_id/services/:service_name/console", WorkspaceLive, :console
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name", WorkspaceLive, :volume
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/files", WorkspaceLive, :volume_files_root
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/files/*path", WorkspaceLive, :volume_file
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git", WorkspaceLive, :volume_git
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/diff/*path", WorkspaceLive, :git_diff
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/staged/*path", WorkspaceLive, :git_staged_diff
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/commits/:sha", WorkspaceLive, :git_commit
    live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/commits/:sha/diff/*path", WorkspaceLive, :git_commit_file
    live "/projects/:project_id/workspaces/:workspace_id/sync", WorkspaceLive, :sync

    live "/system", SystemLive, :index
    live "/system/workspaces", SystemWorkspacesLive, :index
    live "/system/docker", SystemDockerLive, :index
    live "/system/ports", SystemPortsLive, :index
    live "/system/quarantine", SystemQuarantineLive, :index
    live "/connect", ConnectLive, :index

    live "/messages/:agent_id/:msg_id", MessageLive, :show
    get "/messages/:agent_id/:msg_id/raw", OutputController, :show

    get "/raw/:volume_name/*path", RawFileController, :show
    get "/launch/:secret", LaunchController, :launch
  end

  # No CSRF, curl-friendly system endpoints
  scope "/system", BoomLooperWeb do
    pipe_through :api
    get "/log", SystemController, :log
  end
end
