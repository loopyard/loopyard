defmodule LoopyardWeb.Showcase.Scenes.MultiAgent do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "multi-agent",
    description:
      "Three agents on one workspace: the selected one mid-fix, a second " <>
        "running the test suite, a third idle after review, all visible in " <>
        "the rail and the project tree"

  alias LoopyardWeb.Showcase.Mock
  alias LoopyardWeb.Showcase.Scenes.WorkspaceFull

  @impl true
  def component, do: &LoopyardWeb.WorkspaceLive.render/1

  @impl true
  def assigns do
    base = WorkspaceFull.assigns()

    tests =
      Mock.agent(%{
        id: "tests-agent",
        name: "Test runner",
        status: :thinking,
        alive?: true,
        thinking_word: "Running the suite",
        workspace_id: "checkout-fix"
      })

    reviewer =
      Mock.agent(%{id: "reviewer", name: "Reviewer", status: :idle, alive?: true})

    %{base | agents: [base.selected_agent, tests, reviewer]}
  end
end
