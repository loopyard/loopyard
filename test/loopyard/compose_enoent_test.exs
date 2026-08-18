defmodule Loopyard.ComposeEnoentTest do
  @moduledoc """
  The legacy `docker-compose` fallback must return an error tuple, never
  raise, when no compose binary is installed (issue #80). On a fresh
  Colima / OrbStack / Docker Engine box there is no `docker compose` plugin
  and no `docker-compose`, and the raise previously crashed the
  ServiceManager.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Compose

  setup do
    # Force the legacy path (v2 probe = false) and enable the daemon gate so
    # we actually reach System.cmd, with a PATH that contains no compose
    # binary — the exact fresh-Colima condition.
    prev_v2 = :persistent_term.get(:docker_compose_v2, :unchecked)
    prev_enabled = Application.get_env(:loopyard, :docker_enabled)
    prev_path = System.get_env("PATH")

    :persistent_term.put(:docker_compose_v2, false)
    Application.put_env(:loopyard, :docker_enabled, true)
    System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :persistent_term.put(:docker_compose_v2, prev_v2)

      if prev_enabled == nil,
        do: Application.delete_env(:loopyard, :docker_enabled),
        else: Application.put_env(:loopyard, :docker_enabled, prev_enabled)

      if prev_path, do: System.put_env("PATH", prev_path)
    end)

    :ok
  end

  test "compose_cmd returns an error tuple instead of crashing when no compose binary exists" do
    result = Compose.compose_cmd(["version"], 5_000)
    assert {:error, msg} = result
    assert msg =~ "compose" or msg =~ "not found" or msg =~ "not installed"
  end
end
