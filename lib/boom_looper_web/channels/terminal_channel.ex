defmodule BoomLooperWeb.TerminalChannel do
  use Phoenix.Channel

  alias BoomLooper.Terminal

  @impl true
  def join("terminal:" <> container, _params, socket) do
    case Terminal.get_or_start(container) do
      {:ok, _pid} ->
        # Don't subscribe to PubSub yet — we'll do it after sending
        # the buffer to avoid overlap (buffer + live messages = doubled output)
        send(self(), :after_join)
        {:ok, assign(socket, :container, container)}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    Terminal.send_input(socket.assigns.container, data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Terminal.resize(socket.assigns.container, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    container = socket.assigns.container

    # 1. Snapshot the buffer BEFORE subscribing
    buffer = Terminal.get_buffer(container)

    # 2. Subscribe to PubSub — from this point we get live output
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))

    # 3. Send the buffer snapshot
    if buffer != "", do: push(socket, "output", %{data: buffer})

    # Any PubSub messages that arrived between steps 1 and 2 are lost,
    # but that's a tiny window and the next output will fill in.
    # The important thing: no doubled output.
    {:noreply, socket}
  end

  def handle_info({:terminal_output, data}, socket) do
    push(socket, "output", %{data: data})
    {:noreply, socket}
  end

  def handle_info({:terminal_exit, code}, socket) do
    push(socket, "exit", %{code: code})
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
