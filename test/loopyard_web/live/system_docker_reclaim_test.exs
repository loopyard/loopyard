defmodule LoopyardWeb.SystemDockerReclaimTest do
  @moduledoc """
  "Free up space" on /system/docker: the groups with their warnings, and
  removal that re-checks a fresh survey instead of trusting the click.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp row(kind, name, size, opts \\ []),
    do: %{kind: kind, name: name, size: size, note: opts[:note], force: opts[:force] || false}

  defp survey(groups, auto \\ []) do
    base = %{
      stopped_containers: [],
      unused_images: [],
      unknown: [],
      unknown_data: [],
      other_volumes: []
    }

    {:ok, %{auto: auto, groups: Map.merge(base, groups)}}
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{survey: survey(%{}), removed: []} end)
    Application.put_env(:loopyard, :reclaim_survey_fun, fn -> Agent.get(agent, & &1.survey) end)

    Application.put_env(:loopyard, :reclaim_remove_fun, fn rows ->
      Agent.update(agent, &%{&1 | removed: &1.removed ++ rows})
      %{removed: rows, failed: []}
    end)

    on_exit(fn ->
      Application.delete_env(:loopyard, :reclaim_survey_fun)
      Application.delete_env(:loopyard, :reclaim_remove_fun)
    end)

    {:ok, agent: agent}
  end

  defp set(agent, survey), do: Agent.update(agent, &%{&1 | survey: survey})
  defp removed(agent), do: Agent.get(agent, & &1.removed)

  test "each group shows its count, size, warning and rows; volumes from other tools have no bulk button",
       %{conn: conn, agent: agent} do
    set(
      agent,
      survey(%{
        stopped_containers: [row(:container, "great_yalow", 2_640_000, note: "2b01faeedd31")],
        unused_images: [row(:image, "node:24-trixie", 1_240_000_000)],
        unknown: [row(:container, "loopyard-62ddecea-dev-1", 202_000_000)],
        unknown_data: [row(:volume, "loopyard-62ddecea_dind-data", 8_700_000_000)],
        other_volumes: [row(:volume, "observatory_system", 14_500_000_000)]
      })
    )

    {:ok, view, _html} = live(conn, "/system/docker")
    html = render_async(view)

    assert html =~ "Free up space"
    assert html =~ "great_yalow"
    assert html =~ "Their volumes are kept"
    assert html =~ "node:24-trixie"
    assert html =~ "may be ITS containers"
    assert html =~ "uncommitted and unpushed work included"
    assert html =~ "8.7 GB"
    assert html =~ "observatory_system"

    assert has_element?(view, "#reclaim-stopped_containers button[phx-click=reclaim_group]")
    assert has_element?(view, "#reclaim-unknown button[phx-click=reclaim_group][data-confirm]")
    # Other tools' data goes one at a time, and so does any leftover volume
    # with something in it: it may be the only copy of somebody's work.
    refute has_element?(view, "#reclaim-other_volumes button[phx-click=reclaim_group]")
    refute has_element?(view, "#reclaim-unknown_data button[phx-click=reclaim_group]")
    assert has_element?(view, "#reclaim-unknown_data button[phx-click=reclaim_one][data-confirm]")

    assert has_element?(
             view,
             "#reclaim-other_volumes button[phx-click=reclaim_one][data-confirm]"
           )
  end

  test "an empty group is not drawn", %{conn: conn, agent: agent} do
    set(agent, survey(%{unused_images: [row(:image, "node:24-trixie", 10)]}))
    {:ok, view, _html} = live(conn, "/system/docker")
    render_async(view)

    assert has_element?(view, "#reclaim-unused_images")
    refute has_element?(view, "#reclaim-unknown")
    refute has_element?(view, "#reclaim-stopped_containers")
  end

  test "removing a group removes what the FRESH survey lists, containers first", %{
    conn: conn,
    agent: agent
  } do
    set(
      agent,
      survey(%{
        unknown: [
          row(:volume, "loopyard-62ddecea-code", 0),
          row(:container, "loopyard-62ddecea-dev-1", 5)
        ]
      })
    )

    {:ok, view, _html} = live(conn, "/system/docker")
    render_async(view)

    # The world changed after the page was drawn: one more leftover appeared.
    set(
      agent,
      survey(%{
        unknown: [
          row(:volume, "loopyard-62ddecea-code", 0),
          row(:container, "loopyard-62ddecea-dev-1", 5),
          row(:image, "loopyard-62ddecea-dev:latest", 600)
        ]
      })
    )

    view |> element("#reclaim-unknown button[phx-click=reclaim_group]") |> render_click()
    html = render_async(view)

    assert Enum.map(removed(agent), & &1.kind) == [:container, :volume, :image]
    assert html =~ "Removed 3"
  end

  test "a name the fresh survey no longer lists in that group is not removed", %{
    conn: conn,
    agent: agent
  } do
    set(agent, survey(%{other_volumes: [row(:volume, "observatory_system", 100)]}))
    {:ok, view, _html} = live(conn, "/system/docker")
    render_async(view)

    # A forged or stale click: a name that is not in the group, and a real
    # name under the wrong group.
    render_click(view, "reclaim_one", %{
      "group" => "other_volumes",
      "name" => "loopyard-d87b1f7a-code"
    })

    render_async(view)

    render_click(view, "reclaim_one", %{
      "group" => "unused_images",
      "name" => "observatory_system"
    })

    render_async(view)
    render_click(view, "reclaim_one", %{"group" => "nope", "name" => "observatory_system"})
    # No bulk for other tools' volumes, whatever the client sends.
    render_click(view, "reclaim_group", %{"group" => "other_volumes"})
    render_async(view)
    # Nor for leftover volumes that hold something.
    render_click(view, "reclaim_group", %{"group" => "unknown_data"})
    html = render_async(view)

    assert removed(agent) == []
    assert html =~ "Nothing to remove" or html =~ "Couldn&#39;t remove"

    view
    |> element("#reclaim-other_volumes button[phx-value-name=observatory_system]")
    |> render_click()

    render_async(view)
    assert Enum.map(removed(agent), & &1.name) == ["observatory_system"]
  end

  test "when Docker can't be read the section says so instead of failing the page", %{
    conn: conn,
    agent: agent
  } do
    set(agent, {:error, "docker system df failed"})
    {:ok, view, _html} = live(conn, "/system/docker")
    assert render_async(view) =~ "Couldn&#39;t read Docker&#39;s usage"
  end

  test "Loopyard's own leftovers can be run now", %{conn: conn, agent: agent} do
    auto = [%{kind: :volume, name: "loopyard-test-a-code", size: 29_000}]
    set(agent, survey(%{}, auto))
    {:ok, view, _html} = live(conn, "/system/docker")
    assert render_async(view) =~ "1 waiting"

    view |> element("button[phx-click=reclaim_auto]") |> render_click()
    render_async(view)
    assert removed(agent) == auto
  end
end
