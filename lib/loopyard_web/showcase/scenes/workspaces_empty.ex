defmodule LoopyardWeb.Showcase.Scenes.WorkspacesEmpty do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "workspaces-empty",
    description: "First-run /workspaces: the on-ramp shown before any project exists"

  # The /workspaces index with no projects — render/1 is pure over assigns,
  # so the empty-state on-ramp (brand mark + the three creation paths) renders
  # from this one mock map.
  @impl true
  def component, do: &LoopyardWeb.ProjectListLive.render/1

  @impl true
  def assigns do
    %{
      static?: true,
      flash: %{},
      live_action: :index,
      projects: [],
      iex_session: %{level: nil}
    }
  end
end
