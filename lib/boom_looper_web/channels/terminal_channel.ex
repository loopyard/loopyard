defmodule BoomLooperWeb.TerminalChannel do
  use Phoenix.Channel

  alias BoomLooper.Terminal

  @impl true
  def join("terminal:" <> container, _params, socket) do
    case Terminal.get_or_start(container) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))
        send(self(), :send_buffer)
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
  def handle_info(:send_buffer, socket) do
    buffer = Terminal.get_buffer(socket.assigns.container)
    if buffer != "", do: push(socket, "output", %{data: buffer})
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
