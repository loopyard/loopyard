defmodule LoopyardWeb.Showcase.Scenes.WorkspaceFull do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "workspace-full",
    description: "The whole cockpit: project tree, live chat, agents/services rail"

  alias LoopyardWeb.Showcase.Mock

  # The full WorkspaceLive page — render/1 is pure over assigns, so the
  # entire three-pane shell (god-mode tree, chat, context rail) renders
  # from this one mock map. If this scene ever breaks with a KeyError,
  # a view started reading global state in render — that's the smell.
  @impl true
  def component, do: &LoopyardWeb.WorkspaceLive.render/1

  @impl true
  def assigns do
    messages =
      Mock.checkout_conversation() ++
        [
          Mock.user_msg(
            10,
            "Nice. While you're in there, make the quantity stepper keyboard-accessible too.",
            300
          )
        ]

    agent =
      Mock.agent(%{
        status: :thinking,
        alive?: true,
        # Pins the rail's rotating busy word (time-seeded otherwise).
        thinking_word: "Reasoning",
        # A turn mid-flight has already done some work — the live status shows
        # the count from the first call so progress is visible, not silent.
        tool_calls_this_turn: 3,
        messages: messages,
        last_activity_at: Mock.at(310),
        total_input_tokens: 2_310_000,
        total_output_tokens: 74_000,
        total_cache_read_tokens: 1_895_000,
        total_cost_usd: 0.0,
        errors: 0,
        started_at: Mock.at(-7200),
        workspace_id: "checkout-fix",
        docker_mode: :container,
        container: "loopyard-checkout-fix-work"
      })

    %{
      static?: true,
      flash: %{},
      live_action: :chat,
      booting_agent_id: nil,
      mobile_detail_open: false,
      agent_details_expanded: true,
      project: project(),
      workspace: workspace(),
      workspace_entry: workspace_entry(),
      global_tree: global_tree(),
      base_path: "/projects/storefront/workspaces/checkout-fix",
      host: "loopyard.local",
      iex_session: nil,
      nav_agent_id: agent.id,
      nav_service: nil,
      nav_volume: nil,
      agents: [
        agent,
        Mock.agent(%{id: "reviewer", name: "Reviewer", status: :idle, alive?: true})
      ],
      selected_id: agent.id,
      selected_agent: agent,
      selected_service: nil,
      selected_volume: nil,
      service_statuses: service_statuses(),
      services_loaded: true,
      volumes: [],
      volumes_loaded: true,
      changes: %{files: 3, insertions: 41, deletions: 12},
      tab: :chat,
      has_container: true,
      editing_name: nil,
      container_env: [],
      container_logs: [],
      is_local_source?: true,
      sync_status: :ok,
      workspace_state: :running,
      workspace_state_since: Mock.at(-7200),
      docker_connected?: true,
      messages: messages,
      streaming_text: "",
      streaming_thinking:
        "The stepper is two <button> elements with click handlers — no keydown. " <>
          "Arrow keys should adjust quantity when the input has focus; that's " <>
          "the native number-input behavior, so the real fix is using the platform…",
      thinking_word: "Reasoning",
      has_more_messages: false,
      window_tail?: true,
      detail_level: :everything,
      expanded_results: MapSet.new()
    }
  end

  defp project, do: %{id: "storefront", name: "storefront", path: "~/Projects/storefront"}

  defp workspace,
    do: %{id: "checkout-fix", name: "checkout-fix", path: "~/Projects/storefront-checkout-fix"}

  defp workspace_entry do
    %{
      id: "checkout-fix",
      name: "checkout-fix",
      agents: [],
      ports: [%{port: 4007, url: "http://loopyard.local:4007"}],
      needs_you: nil,
      broken: nil,
      last_activity_at: Mock.at(310),
      changes: %{files: 3, insertions: 41, deletions: 12}
    }
  end

  defp global_tree do
    [
      %{
        id: "gardenparty",
        name: "gardenparty",
        path: "~/Projects/gardenparty",
        git_url: nil,
        workspaces: [
          ws("gp-main", "main", ports: [%{port: 4003, url: "http://loopyard.local:4003"}])
        ]
      },
      %{
        id: "mobile-api",
        name: "mobile-api",
        path: "~/Projects/mobile-api",
        git_url: nil,
        workspaces: [ws("ma-main", "main", [])]
      },
      %{
        id: "storefront",
        name: "storefront",
        path: "~/Projects/storefront",
        git_url: nil,
        workspaces: [
          ws("sf-main", "main", ports: [%{port: 4004, url: "http://loopyard.local:4004"}]),
          ws("checkout-fix", "checkout-fix",
            ports: [%{port: 4007, url: "http://loopyard.local:4007"}],
            agents: [
              %{
                id: "demo-agent",
                workspace_id: "checkout-fix",
                name: "Claude",
                status: :thinking,
                quarantined: nil,
                active_tool: nil,
                model: "claude-opus-4-8",
                cost: nil,
                last_activity_at: Mock.at(310),
                alive?: true
              }
            ]
          )
        ]
      }
    ]
  end

  defp ws(id, name, opts) do
    %{
      id: id,
      name: name,
      agents: Keyword.get(opts, :agents, []),
      ports: Keyword.get(opts, :ports, []),
      needs_you: nil,
      broken: nil,
      last_activity_at: Mock.at(0),
      changes: nil
    }
  end

  defp service_statuses do
    [
      %{
        name: "dev",
        status: :running,
        health: :healthy,
        ports: %{},
        host_port: 4007,
        exposed: false
      },
      %{name: "postgres", status: :running, health: :healthy, ports: %{}, host_port: nil}
    ]
  end
end
