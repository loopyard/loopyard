defmodule Loopyard.Harness.ACPImagePromptTest do
  @moduledoc """
  An attached screenshot reaches the model as an ACP `image` content block in
  the same `session/prompt` as the text — when the adapter advertises
  `promptCapabilities.image` — so it SEES the picture without a Read.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Attachments
  alias Loopyard.Harness.ACP
  alias Loopyard.Harness.ACP.Connection
  alias Loopyard.Test.FakeVolumeIO

  defmodule FakeTransport do
    @moduledoc false
    @behaviour Loopyard.Harness.ACP.Transport
    use GenServer

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def send_msg(pid, message), do: GenServer.cast(pid, {:send, message})
    @impl true
    def close(pid), do: GenServer.stop(pid, :normal)

    @impl GenServer
    def init(opts), do: {:ok, %{test: Keyword.fetch!(opts, :test)}}

    @impl GenServer
    def handle_cast({:send, message}, state) do
      send(state.test, {:sent, message})
      {:noreply, state}
    end
  end

  @shot %{
    path: "/workspace/.loopyard/uploads/20260901T1-ab-shot.png",
    name: "20260901T1-ab-shot.png",
    mime: "image/png",
    size: 4
  }

  setup do
    prev = Application.get_env(:loopyard, :volume_reader)
    Application.put_env(:loopyard, :volume_reader, FakeVolumeIO)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:loopyard, :volume_reader, prev),
        else: Application.delete_env(:loopyard, :volume_reader)
    end)

    :ok
  end

  defp ready_conn(image?) do
    {:ok, conn} =
      Connection.start_link(
        transport: FakeTransport,
        transport_opts: [test: self()],
        cwd: "/workspace",
        volume: "loopyard-imgws-code"
      )

    assert_receive {:sent, %{"method" => "initialize", "id" => init_id}}
    caps = if image?, do: %{"promptCapabilities" => %{"image" => true}}, else: %{}
    send(conn, {:acp_msg, %{"id" => init_id, "result" => %{"agentCapabilities" => caps}}})
    assert_receive {:sent, %{"method" => "session/new", "id" => new_id}}
    send(conn, {:acp_msg, %{"id" => new_id, "result" => %{"sessionId" => "sess-img"}}})
    :ok = Connection.await_ready(conn, 1_000)
    conn
  end

  test "Harness.ACP.stream sends the screenshot inline as an image block" do
    FakeVolumeIO.seed("loopyard-imgws-code", [{@shot.path, "PNG!"}])
    conn = ready_conn(true)
    text = Attachments.annotate("What's wrong here?", [@shot])

    # Blocks are built in the caller (this process — where the fake reader's
    # seed lives); the turn is then consumed like ChatAgent's stream Task does.
    stream = ACP.stream(conn, text)
    task = Task.async(fn -> Enum.to_list(stream) end)

    assert_receive {:sent, %{"method" => "session/prompt", "id" => id} = frame}, 1_000

    assert [
             %{"type" => "text", "text" => ^text},
             %{"type" => "image", "data" => data, "mimeType" => "image/png"}
           ] = frame["params"]["prompt"]

    assert Base.decode64!(data) == "PNG!"

    send(conn, {:acp_msg, %{"id" => id, "result" => %{"stopReason" => "end_turn"}}})
    assert is_list(Task.await(task, 1_000))
  end

  test "an adapter without image support gets the text (marker line) only" do
    FakeVolumeIO.seed("loopyard-imgws-code", [{@shot.path, "PNG!"}])
    conn = ready_conn(false)
    text = Attachments.annotate("What's wrong here?", [@shot])

    stream = ACP.stream(conn, text)
    task = Task.async(fn -> Enum.to_list(stream) end)

    assert_receive {:sent, %{"method" => "session/prompt", "id" => id} = frame}, 1_000
    assert frame["params"]["prompt"] == [%{"type" => "text", "text" => text}]

    send(conn, {:acp_msg, %{"id" => id, "result" => %{"stopReason" => "end_turn"}}})
    Task.await(task, 1_000)
  end
end
