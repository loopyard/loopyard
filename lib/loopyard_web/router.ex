defmodule LoopyardWeb.Router do
  use LoopyardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LoopyardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug LoopyardWeb.Plugs.BasicAuth
  end

  pipeline :api do
    plug :accepts, ["json", "text"]
  end

  # Aural audio + diag — no CSRF (POSTs come from the audio page
  # itself, JSON only). No session. Pure media endpoints.
  pipeline :aural do
    plug :accepts, ["*/*", "json", "html", "mpeg"]
  end

  # Aural LV ships from the `:aural` package. Each visitor lands on
  # a per-channel URL `/aural/:channel_id`; the bare `/aural` route
  # generates a fresh ID and 302s.
  scope "/" do
    pipe_through :browser
    live "/aural/:channel_id", AuralWeb.Live, :index
  end

  scope "/", LoopyardWeb do
    pipe_through :browser

    # One live_session over the whole app so `<.link navigate>` between
    # LiveViews stays on the websocket (no full page reload). That's what lets
    # the ambient-audio layer in the root layout (and the connection socket)
    # survive navigation — the bed keeps playing as you move around — and it
    # makes cross-view navigation snappier as a bonus.
    live_session :app, root_layout: {LoopyardWeb.Layouts, :root} do
      # Homepage = the live status dashboard (Workspaces / Remote / System /
      # Operated cards). The project → workspace list lives at /workspaces.
      live "/", DashboardLive, :index
      live "/workspaces", ProjectListLive, :index
      # Opens (creating on first visit) the operating identity's operator agent.
      live "/operator", OperatorLive, :index
      # DECISIONS — every pending question/secret/approval across all agents,
      # one deck (Loopyard.Attention). `/decisions/:agent/:msg` is one decision
      # with its discussion thread. `/review*` is the old name, kept so pasted
      # links keep working.
      live "/decisions", ReviewLive, :index
      live "/decisions/history", ReviewLive, :history
      live "/decisions/:agent_id/:msg_id", ReviewLive, :item
      live "/review", ReviewLive, :index
      live "/review/history", ReviewLive, :history
      live "/review/:agent_id/:msg_id", ReviewLive, :item
      live "/projects/:project_id/workspaces/:workspace_id/decisions", ReviewLive, :workspace
      live "/projects/:project_id/workspaces/:workspace_id/review", ReviewLive, :workspace
      # Full-page ambient-sound control. In the live_session so navigating here
      # (and back) is a live patch — the root-layout audio engine keeps playing.
      live "/sound", SoundLive, :index
      # New-project flow — its own screens (static, must precede /projects/:project_id).
      live "/projects/new", ProjectListLive, :new
      live "/projects/new/scratch", ProjectListLive, :new_scratch
      live "/projects/new/folder", ProjectListLive, :new_folder
      live "/projects/new/github", ProjectListLive, :new_github
      live "/projects/:project_id", ProjectLive, :index
      # New-workspace flow gets its own screen too.
      live "/projects/:project_id/new", ProjectLive, :new_workspace
      live "/projects/:project_id/settings", ProjectLive, :settings
      live "/projects/:project_id/workspaces/:workspace_id", WorkspaceLive, :index
      live "/projects/:project_id/workspaces/:workspace_id/new", WorkspaceLive, :new
      # Bare "…/agents" (no id) lands on the workspace, which picks an agent —
      # an agent linking "open the workspace's agents" shouldn't hit a hard 404.
      live "/projects/:project_id/workspaces/:workspace_id/agents", WorkspaceLive, :index
      live "/projects/:project_id/workspaces/:workspace_id/agents/:id", WorkspaceLive, :chat

      live "/projects/:project_id/workspaces/:workspace_id/agents/:id/container",
           WorkspaceLive,
           :container

      live "/projects/:project_id/workspaces/:workspace_id/agents/:id/context",
           WorkspaceLive,
           :context_panel

      live "/projects/:project_id/workspaces/:workspace_id/agents/:id/info",
           WorkspaceLive,
           :info

      live "/projects/:project_id/workspaces/:workspace_id/services", WorkspaceLive, :services

      live "/projects/:project_id/workspaces/:workspace_id/services/:service_name",
           WorkspaceLive,
           :service

      live "/projects/:project_id/workspaces/:workspace_id/services/:service_name/console",
           WorkspaceLive,
           :console

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name",
           WorkspaceLive,
           :volume

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/files",
           WorkspaceLive,
           :volume_files_root

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/files/*path",
           WorkspaceLive,
           :volume_file

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git",
           WorkspaceLive,
           :volume_git

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/history",
           WorkspaceLive,
           :volume_history

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/diff/*path",
           WorkspaceLive,
           :git_diff

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/staged/*path",
           WorkspaceLive,
           :git_staged_diff

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/commits/:sha",
           WorkspaceLive,
           :git_commit

      live "/projects/:project_id/workspaces/:workspace_id/volumes/:volume_name/git/commits/:sha/diff/*path",
           WorkspaceLive,
           :git_commit_file

      live "/projects/:project_id/workspaces/:workspace_id/sync", WorkspaceLive, :sync

      # Workstations — each identity has its own URL. Visiting one makes it the one
      # you're operating as. /workstations is the list (switch / create); bare
      # singular /workstation → your current id.
      get "/workstation", WorkstationController, :index
      post "/workstations/create", WorkstationController, :create
      live "/workstations", WorkstationLive, :index
      live "/workstations/:id", WorkstationLive, :show
      # Sub-pages of a workstation (own URL each, not collapsibles). Literal segments
      # so they win over the `/workstations/:id/:tool` integration route below.
      live "/workstations/:id/console", WorkstationLive, :console
      live "/workstations/:id/env", WorkstationLive, :env

      live "/system", SystemLive, :index
      live "/system/workspaces", SystemWorkspacesLive, :index
      live "/system/docker", SystemDockerLive, :index
      live "/system/ports", SystemPortsLive, :index
      live "/system/quarantine", SystemQuarantineLive, :index
      live "/system/events", SystemEventsLive, :index
      live "/system/sagas", SystemSagasLive, :index
      live "/system/orphans", SystemOrphansLive, :index
      live "/system/recovery", SystemRecoveryLive, :index
      live "/system/secrets", SystemSecretsLive, :index

      live "/messages/:agent_id/:msg_id", MessageLive, :show
    end

    get "/messages/:agent_id/:msg_id/raw", OutputController, :show

    get "/raw/:volume_name/*path", RawFileController, :show
    get "/launch/:secret", LaunchController, :launch
  end

  # No CSRF, curl-friendly system endpoints
  scope "/system", LoopyardWeb do
    pipe_through :api
    get "/log", SystemController, :log
  end

  # Transfer credentials from your Mac into a *named* workstation. The id is in
  # the URL — a headless curl always names which identity it's pushing to (never
  # an implicit server-side "current"). The Workstation page bakes your current
  # id into the commands it shows, so copy-paste is unchanged.
  #  curl -fsS http://localhost:4000/workstations/brad/setup.sh | sh  # everything
  #  gh auth token | curl -T - .../workstations/brad/env/GITHUB_TOKEN  # one env var
  #  curl -T - .../workstations/brad/file/.codex/auth.json < ~/.codex/auth.json  # one file
  # Local requests need no auth (a curl on this machine is already trusted);
  # tunnel/remote requests need the PushToken (see PushAuth). Defined BEFORE the
  # `/workstations/:id/:tool` page route so these literal sub-paths win.
  scope "/workstations", LoopyardWeb do
    pipe_through :api
    get "/:id/:tool/docs.md", IntegrationController, :doc
    get "/:id/:tool/setup.sh", SetupController, :tool_script
    get "/:id/setup.sh", SetupController, :script
    put "/:id/env/:key", EnvController, :put
    put "/:id/file/*path", FileController, :put
  end

  # Per-tool integration pages, scoped to a workstation. After the api scope so the
  # literal sub-paths above (setup.sh, env, file, docs.md) win over `:tool`.
  scope "/", LoopyardWeb do
    pipe_through :browser
    live "/workstations/:id/:tool", WorkstationToolLive, :show
  end

  # Aural transport routes ship from the `:aural` package via the
  # `aural_routes/0` macro — mounts stream.mp3 for each channel,
  # the diag loopback, and a bare `/aural` → `/aural/<new_id>`
  # redirect. All outside the :browser pipeline (no CSRF).
  import Aural.Router

  scope "/aural" do
    pipe_through :aural
    aural_routes()
  end
end
