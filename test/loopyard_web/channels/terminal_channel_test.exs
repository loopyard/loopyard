defmodule LoopyardWeb.TerminalChannelTest do
  use LoopyardWeb.ChannelCase

  alias LoopyardWeb.TerminalChannel

  describe "join" do
    test "returns error for non-running container" do
      assert {:error, %{reason: _}} =
               socket(LoopyardWeb.UserSocket, "user", %{})
               |> subscribe_and_join(
                 TerminalChannel,
                 "terminal:nonexistent-#{:rand.uniform(100_000)}"
               )
    end
  end

  describe "with Docker container" do
    @describetag :docker

    setup do
      container = "#{Loopyard.Docker.prefix()}channel-test-#{:rand.uniform(100_000)}"

      {_, 0} =
        System.cmd("docker", ["run", "-d", "--name", container, "alpine:latest", "sleep", "300"],
          stderr_to_stdout: true
        )

      on_exit(fn ->
        case Registry.lookup(Loopyard.TerminalRegistry, container) do
          [{pid, _}] -> GenServer.stop(pid, :normal)
          [] -> :ok
        end

        Process.sleep(50)
        System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
      end)

      %{container: container}
    end

    test "join succeeds for running container", %{container: container} do
      {:ok, _, _socket} =
        socket(LoopyardWeb.UserSocket, "user", %{})
        |> subscribe_and_join(TerminalChannel, "terminal:#{container}")
    end

    test "input is forwarded to terminal", %{container: container} do
      {:ok, _, socket} =
        socket(LoopyardWeb.UserSocket, "user", %{})
        |> subscribe_and_join(TerminalChannel, "terminal:#{container}")

      push(socket, "input", %{"data" => "echo test\n"})
      assert_push "output", %{data: _}, 3_000
    end

    test "resize does not crash", %{container: container} do
      {:ok, _, socket} =
        socket(LoopyardWeb.UserSocket, "user", %{})
        |> subscribe_and_join(TerminalChannel, "terminal:#{container}")

      push(socket, "resize", %{"cols" => 120, "rows" => 40})
      Process.sleep(100)
    end
  end
end
