defmodule Loopyard.Workspace.DestructorImagesTest do
  @moduledoc """
  A destroyed workspace takes the images its dev cluster built with it — and
  only those: one id is never the start of another's.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Workspace.Destructor

  test "the workspace's own built images, nothing else" do
    prefix = Loopyard.Docker.prefix()

    refs = [
      "#{prefix}62ddecea-dev:latest",
      "#{prefix}62ddecea-worker:latest",
      "#{prefix}62ddecea-dev:<none>",
      "#{prefix}62ddecea9-dev:latest",
      "#{prefix}62dd-dev:latest",
      "loopyard-workspace-base:v5",
      "postgres:16",
      "<none>:<none>"
    ]

    assert Destructor.workspace_images("62ddecea", fn -> refs end) == [
             "#{prefix}62ddecea-dev:latest",
             "#{prefix}62ddecea-worker:latest"
           ]

    assert Destructor.workspace_images("nope", fn -> refs end) == []
  end
end
