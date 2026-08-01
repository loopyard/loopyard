defmodule Loopyard.ComposePortabilityTest do
  @moduledoc """
  `.loopyard/workspace/docker-compose.yml` is tracked in git, so git carries it
  to every branch. That only works if it names no workspace.

  It used to name one. `WriteFile` resolved `${CODE_VOLUME}` before the bytes
  reached disk, so the committed file read `name: loopyard-261219b7-code` — and
  on any other branch that's a foreign volume. The cluster still came up,
  because `Compose.normalize_code_volume_names/2` quietly corrects a foreign
  name at process time, which is exactly why it went unnoticed: the system
  worked while the file lied. An agent reading it saw another workspace's
  infrastructure and rewrote it instead of reusing it.

  The rule: the FILE stays portable, resolution happens when the cluster starts.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Compose

  @portable """
  services:
    dev:
      image: elixir:1.19
      volumes:
        - ${CODE_VOLUME}:/workspace
  volumes:
    code:
      external: true
      name: ${CODE_VOLUME}
  """

  describe "resolution happens at run time, not write time" do
    test "the placeholder resolves to THIS workspace's volume when processed" do
      {:ok, json} = Compose.process_agent_compose(@portable, "ws-abc")

      assert json =~ "#{Loopyard.Docker.prefix()}ws-abc-code"
      refute json =~ "${CODE_VOLUME}"
    end

    test "a compose naming ANOTHER workspace's volume is corrected, not mounted" do
      foreign =
        String.replace(
          @portable,
          "${CODE_VOLUME}",
          "#{Loopyard.Docker.prefix()}someone-else-code"
        )

      {:ok, json} = Compose.process_agent_compose(foreign, "ws-abc")

      # Fork safety: mounting the source's code from a fork is silent
      # cross-workspace corruption.
      refute json =~ "#{Loopyard.Docker.prefix()}someone-else-code"
      assert json =~ "#{Loopyard.Docker.prefix()}ws-abc-code"
    end

    test "${WORKSPACE_ID} still resolves — it moved to this seam, it didn't vanish" do
      compose = """
      services:
        dev:
          image: elixir:1.19
          container_name: brain-${WORKSPACE_ID}
          volumes:
            - ${CODE_VOLUME}:/workspace
      """

      {:ok, json} = Compose.process_agent_compose(compose, "ws-abc")

      assert json =~ "brain-ws-abc"
      refute json =~ "${WORKSPACE_ID}"
    end
  end
end
