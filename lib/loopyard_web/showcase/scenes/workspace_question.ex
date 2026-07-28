defmodule LoopyardWeb.Showcase.Scenes.WorkspaceQuestion do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "workspace-question",
    description: "Full cockpit with a needs-you question card waiting"

  alias LoopyardWeb.Showcase.Scenes.{QuestionCard, WorkspaceFull}

  @impl true
  def component, do: &LoopyardWeb.WorkspaceLive.render/1

  # The full-shell scene with the question-card transcript swapped in — one
  # source of truth for the shell mock, one for the question narrative.
  @impl true
  def assigns do
    q = QuestionCard.assigns()

    base = WorkspaceFull.assigns()
    agent = %{base.selected_agent | messages: q.messages}

    %{
      base
      | messages: q.messages,
        streaming_thinking: "",
        thinking_word: nil,
        selected_agent: agent,
        agents: List.replace_at(base.agents, 0, agent)
    }
  end
end
