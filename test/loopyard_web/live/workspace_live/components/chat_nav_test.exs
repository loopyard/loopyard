defmodule LoopyardWeb.Live.WorkspaceLive.Components.ChatNavTest do
  @moduledoc """
  The workspace category nav's pure routing: which pill is active for a
  live_action, and where each pill points (content-first: the last thing you
  had open there, else the first item, else the category root).
  """
  use ExUnit.Case, async: true

  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatNav

  describe "active_category/1" do
    test "services routes light the Services pill" do
      for a <- [:service, :services, :console],
          do: assert(ChatNav.active_category(a) == :services)
    end

    test "every volume/git/sync route lights the Volumes pill" do
      for a <- [:volume, :volume_files_root, :volume_file, :volume_git, :git_commit, :sync],
          do: assert(ChatNav.active_category(a) == :volumes)
    end

    test "agent sub-views and anything unknown are Agents" do
      for a <- [:index, :agent, :container, :info, :context, :whatever],
          do: assert(ChatNav.active_category(a) == :agents)
    end
  end

  describe "category_href/2" do
    @base "/projects/p/workspaces/w"

    test "agents: the agent you had open, else the first agent, else the root" do
      assert ChatNav.category_href(:agents, %{nav_agent_id: "a9", agents: [], base_path: @base}) ==
               "#{@base}/agents/a9"

      assert ChatNav.category_href(:agents, %{
               agents: [%{id: "a1"}, %{id: "a2"}],
               base_path: @base
             }) ==
               "#{@base}/agents/a1"

      assert ChatNav.category_href(:agents, %{agents: [], base_path: @base}) == @base
    end

    test "services: the service you had open, else the first, else the list" do
      assert ChatNav.category_href(:services, %{nav_service: "web", base_path: @base}) =~ "web"

      href =
        ChatNav.category_href(:services, %{service_statuses: [%{name: "db"}], base_path: @base})

      assert href =~ @base
      assert ChatNav.category_href(:services, %{base_path: @base}) == "#{@base}/services"
    end

    test "volumes: the volume you had open, else the first, else the list" do
      assert ChatNav.category_href(:volumes, %{nav_volume: "code", base_path: @base}) =~ "code"
      href = ChatNav.category_href(:volumes, %{volumes: [%{name: "vol-1"}], base_path: @base})
      assert href =~ @base
    end
  end

  describe "current_ws_port/2" do
    test "nil tree → nil" do
      assert ChatNav.current_ws_port(nil, "w") == nil
    end
  end
end
