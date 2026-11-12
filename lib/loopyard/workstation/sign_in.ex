defmodule Loopyard.Workstation.SignIn do
  @moduledoc """
  Guided, in-app sign-in for a workstation integration — "Sign in to Claude"
  as three taps instead of a terminal session.

  The vendor CLI already has a headless login (`claude setup-token`): it prints
  an authorize URL, takes the code the vendor's page shows after you approve,
  and prints a long-lived token. This module DRIVES that CLI so the human never
  touches a terminal and the token never touches a browser:

      begin/2        → run the CLI in a throwaway container, read the URL
      (human opens the URL on ANY device, approves, copies the code)
      submit_code/3  → type the code into the CLI, read the token
                     → `Env.put/3` stores it on the workstation; its agents
                       reload themselves (`Workstation.reload_agents/1`)

  Which CLI, which env key and what a token looks like are DATA on the
  integration (`Integration` → `:sign_in`); nothing here names a vendor.

  One process for the whole app (sign-ins are rare and short), holding at most
  one flow per `{workstation, tool}`. Each flow runs in its OWN `--rm`
  container from the stock base image with no volumes: the CLI only PRINTS the
  token, so there is nothing to persist and no identity `$HOME` to disturb.
  The container is `Resources.track/4`ed against this process, so a crash here
  cannot strand it.

  Secrets: the transcript buffer holds the token for the instant between the
  CLI printing it and `Env.put/3`; it is dropped at once, never logged, and
  `format_status/1` keeps it out of crash reports. Events carry phase + URL
  only.
  """
  use GenServer

  require Logger

  alias Loopyard.Docker
  alias Loopyard.Events.Workstation, as: Events
  alias Loopyard.Events.Workstation.SignInChanged
  alias Loopyard.Workstation
  alias Loopyard.Workstation.{Env, Integration}

  # A human is in the loop (open a page, sign in, copy a code) — generous, but
  # bounded so an abandoned flow doesn't hold a container forever.
  @flow_timeout_ms 10 * 60_000
  # Code → token is one HTTPS round trip inside the CLI.
  @exchange_timeout_ms 60_000
  @max_buffer 32_000
  @max_code_bytes 2_048

  @type status :: %{phase: SignInChanged.phase(), url: String.t() | nil, error: String.t() | nil}

  # ── API ──────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Does this integration have a guided sign-in?"
  @spec supported?(String.t()) :: boolean()
  def supported?(tool), do: is_map(spec(tool))

  @doc "Start (or restart) the sign-in for `tool` on workstation `id`."
  @spec begin(String.t(), String.t()) :: :ok | {:error, term()}
  def begin(id, tool), do: call({:begin, id, tool})

  @doc "Hand the flow the code the vendor's page showed. Only while it is waiting for one."
  @spec submit_code(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_waiting | :invalid_code}
  def submit_code(id, tool, code) when is_binary(code), do: call({:submit_code, id, tool, code})
  def submit_code(_id, _tool, _code), do: {:error, :invalid_code}

  @doc "Abandon the flow (no-op when none is running)."
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(id, tool) do
    _ = call({:cancel, id, tool})
    :ok
  end

  @doc "Where the flow stands — `%{phase: :idle}` when none is running."
  @spec status(String.t(), String.t()) :: status()
  def status(id, tool) do
    case call({:status, id, tool}) do
      %{phase: _} = status -> status
      _ -> %{phase: :idle, url: nil, error: nil}
    end
  end

  defp call(msg) do
    GenServer.call(__MODULE__, msg, 15_000)
  catch
    :exit, reason -> {:error, {:sign_in_unavailable, reason}}
  end

  # ── pure: read the CLI's transcript ──────────────────────────────────────

  @doc """
  Strip terminal control sequences from a raw PTY transcript. The CLIs are
  full-screen TUIs: they position text with cursor moves instead of spaces, so
  what's left is the visible characters with most whitespace gone — match on
  it with whitespace-tolerant patterns.
  """
  @spec clean(binary()) :: String.t()
  def clean(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, " ")
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)/, "")
    |> String.replace(~r/\e[()][A-Za-z0-9]|\e[=>]/, "")
    |> String.replace("\r", "\n")
    |> String.replace(~r/[^\x20-\x7E\n]/u, "")
  end

  @doc """
  The authorize URL in a cleaned transcript, once it is COMPLETE (followed by
  whitespace — a chunk boundary can land mid-URL). `nil` until then.
  """
  @spec find_url(String.t()) :: String.t() | nil
  def find_url(text) do
    case Regex.run(~r{(https://[^\s]*oauth[^\s]*)\s}, text) do
      [_, url] -> url
      _ -> nil
    end
  end

  @doc "The token (by its integration's prefix), once complete. `nil` until then."
  @spec find_token(String.t(), String.t()) :: String.t() | nil
  def find_token(text, prefix) when is_binary(prefix) and prefix != "" do
    case Regex.run(~r/(#{Regex.escape(prefix)}[A-Za-z0-9_-]{20,})[^A-Za-z0-9_-]/, text) do
      [_, token] -> token
      _ -> nil
    end
  end

  @doc "Did the CLI report that the vendor refused the code?"
  @spec rejected?(String.t()) :: boolean()
  def rejected?(text),
    do: Regex.match?(~r/OAuth\s*error|Invalid\s*code|Press\s*Enter\s*to\s*retry/i, text)

  # ── server ───────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{flows: %{}}}

  @impl true
  def handle_call({:begin, id, tool}, _from, state) do
    key = {id, tool}

    cond do
      is_nil(spec(tool)) ->
        {:reply, {:error, :unsupported}, state}

      not Workstation.exists?(id) ->
        {:reply, {:error, :not_found}, state}

      true ->
        state = drop(state, key)
        container = "#{Docker.prefix()}signin-#{id}-#{System.unique_integer([:positive])}"

        case transport().open.(container, spec(tool).command) do
          {:ok, handle} ->
            Loopyard.Resources.track(self(), :signin_container, container, fn ->
              remove_container(container)
            end)

            flow = %{
              handle: handle,
              container: container,
              spec: spec(tool),
              buf: "",
              phase: :starting,
              url: nil,
              timer: Process.send_after(self(), {:flow_timeout, key, handle}, @flow_timeout_ms)
            }

            publish(key, flow)
            {:reply, :ok, put_in(state.flows[key], flow)}

          {:error, reason} ->
            Loopyard.EventLog.warning(
              "workstation",
              "sign-in could not start: #{inspect(reason)}"
            )

            publish_failed(key, "Couldn't start the sign-in — Docker isn't reachable right now.")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:submit_code, id, tool, code}, _from, state) do
    key = {id, tool}
    code = String.trim(code)

    case state.flows[key] do
      %{phase: :awaiting_code} = flow ->
        if valid_code?(code) do
          # The CLI's prompt is a raw-mode TUI: Enter is CR.
          transport().write.(flow.handle, code <> "\r")
          Process.cancel_timer(flow.timer)

          flow = %{
            flow
            | phase: :exchanging,
              # Fresh buffer: nothing printed BEFORE the code can match now.
              buf: "",
              timer:
                Process.send_after(
                  self(),
                  {:flow_timeout, key, flow.handle},
                  @exchange_timeout_ms
                )
          }

          publish(key, flow)
          {:reply, :ok, put_in(state.flows[key], flow)}
        else
          {:reply, {:error, :invalid_code}, state}
        end

      _ ->
        {:reply, {:error, :not_waiting}, state}
    end
  end

  def handle_call({:cancel, id, tool}, _from, state) do
    key = {id, tool}
    had? = Map.has_key?(state.flows, key)
    state = drop(state, key)
    if had?, do: publish_phase(key, :idle)
    {:reply, :ok, state}
  end

  def handle_call({:status, id, tool}, _from, state) do
    reply =
      case state.flows[{id, tool}] do
        nil -> %{phase: :idle, url: nil, error: nil}
        flow -> %{phase: flow.phase, url: flow.url, error: nil}
      end

    {:reply, reply, state}
  end

  def handle_call(msg, _from, state) do
    unknown(:call, msg)
    {:reply, {:error, :unknown}, state}
  end

  @impl true
  def handle_cast(msg, state) do
    unknown(:cast, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({handle, {:data, data}}, state) when is_binary(data) do
    case find_flow(state, handle) do
      {key, flow} -> {:noreply, advance(state, key, %{flow | buf: tail(flow.buf <> data)})}
      nil -> {:noreply, state}
    end
  end

  def handle_info({handle, {:exit_status, _code}}, state) do
    case find_flow(state, handle) do
      {key, %{phase: phase}} when phase != :storing ->
        {:noreply, fail(state, key, "The sign-in stopped before it finished. Start it again.")}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:flow_timeout, key, handle}, state) do
    case state.flows[key] do
      %{handle: ^handle, phase: :exchanging} ->
        {:noreply, fail(state, key, "Claude didn't answer in time. Start the sign-in again.")}

      %{handle: ^handle} ->
        {:noreply, fail(state, key, "The sign-in timed out waiting for a code. Start it again.")}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:stored, key, result}, state) do
    case {state.flows[key], result} do
      {%{phase: :storing}, :ok} ->
        state = drop(state, key)
        publish_phase(key, :done)
        {:noreply, state}

      {%{phase: :storing}, _error} ->
        {:noreply, fail(state, key, "Signed in, but the token couldn't be saved. Try again.")}

      _ ->
        {:noreply, state}
    end
  end

  # Task replies / monitors from the storing task.
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    unknown(:info, msg)
    {:noreply, state}
  end

  # The transcript can hold a token; keep it out of crash reports and :sys.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{flows: flows} = state ->
        %{state | flows: Map.new(flows, fn {k, f} -> {k, %{f | buf: "[redacted]"}} end)}

      other ->
        other
    end)
  end

  # ── flow steps ───────────────────────────────────────────────────────────

  defp advance(state, key, flow) do
    text = clean(flow.buf)
    token = find_token(text, flow.spec.token_prefix)

    cond do
      # A token wins from any phase (a CLI that caught its own callback never
      # asks for a code).
      token ->
        store(state, key, flow, token)

      flow.phase == :starting ->
        case find_url(text) do
          nil ->
            put_in(state.flows[key], flow)

          url ->
            flow = %{flow | phase: :awaiting_code, url: url}
            publish(key, flow)
            put_in(state.flows[key], flow)
        end

      flow.phase == :exchanging and rejected?(text) ->
        fail(
          put_in(state.flows[key], flow),
          key,
          "Claude didn't accept that code. Start again and paste it exactly as shown."
        )

      true ->
        put_in(state.flows[key], flow)
    end
  end

  defp store(state, key, flow, token) do
    {id, _tool} = key
    env_key = flow.spec.env
    server = self()
    close(flow)

    # Env.put shells out to Docker (sync into the home volume) and restarts the
    # identity's agents — off this process so other flows keep moving.
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      result =
        try do
          Env.put(env_key, token, id)
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(server, {:stored, key, result})
    end)

    # Token is on its way to the store; nothing here keeps a copy.
    put_in(state.flows[key], %{flow | phase: :storing, buf: "", handle: nil})
  end

  defp fail(state, key, message) do
    state = drop(state, key)
    publish_failed(key, message)
    state
  end

  defp drop(state, key) do
    case Map.pop(state.flows, key) do
      {nil, _} ->
        state

      {flow, flows} ->
        close(flow)
        %{state | flows: flows}
    end
  end

  defp close(flow) do
    if flow[:timer], do: Process.cancel_timer(flow.timer)
    if flow.handle, do: transport().close.(flow.handle, flow.container)
    Loopyard.Resources.release(:signin_container, flow.container)
    :ok
  end

  defp find_flow(state, handle) do
    Enum.find(state.flows, fn {_key, flow} -> flow.handle == handle end)
  end

  defp tail(buf) when byte_size(buf) > @max_buffer,
    do: binary_part(buf, byte_size(buf) - @max_buffer, @max_buffer)

  defp tail(buf), do: buf

  # What the vendor's page hands back: one printable line, no whitespace.
  defp valid_code?(code) do
    code != "" and byte_size(code) <= @max_code_bytes and
      Regex.match?(~r/\A[\x21-\x7E]+\z/, code)
  end

  defp spec(tool) do
    case Integration.get(tool) do
      %{sign_in: %{command: _, token_prefix: _} = sign_in, env: env} when is_binary(env) ->
        Map.put(sign_in, :env, env)

      _ ->
        nil
    end
  end

  # ── events ───────────────────────────────────────────────────────────────

  defp publish({id, tool}, flow) do
    Events.publish(%SignInChanged{
      workstation_id: id,
      tool: tool,
      phase: flow.phase,
      url: flow.url
    })
  end

  defp publish_phase({id, tool}, phase),
    do: Events.publish(%SignInChanged{workstation_id: id, tool: tool, phase: phase})

  defp publish_failed({id, tool}, message) do
    Events.publish(%SignInChanged{
      workstation_id: id,
      tool: tool,
      phase: :failed,
      error: message
    })
  end

  defp unknown(kind, msg) do
    Logger.warning("[Workstation.SignIn] unexpected #{kind}: #{inspect(msg, limit: 3)}")

    :telemetry.execute([:loopyard, :actor, :unknown_message], %{count: 1}, %{
      actor: __MODULE__,
      kind: kind
    })
  end

  # ── transport (the seam tests replace) ───────────────────────────────────

  # `open.(container, command)` → `{:ok, handle}`; the process then receives
  # `{handle, {:data, binary}}` / `{handle, {:exit_status, n}}`.
  defp transport do
    Application.get_env(:loopyard, :sign_in_transport, %{
      open: &docker_open/2,
      write: &docker_write/2,
      close: &docker_close/2
    })
  end

  # `script` gives the CLI the PTY its TUI needs; the wide `stty` keeps the URL
  # and the token on ONE line (at 80 columns the TUI hard-wraps both, and a
  # wrapped token is indistinguishable from a short one).
  defp docker_open(container, command) do
    inner = ~s(script -qfc "stty cols 2000 rows 50; exec #{command}" /dev/null)

    case Docker.open_port([
           "run",
           "--rm",
           "-i",
           "--name",
           container,
           "--memory",
           "1g",
           Loopyard.Workspace.WorkContainer.image(),
           "sh",
           "-c",
           inner
         ]) do
      port when is_port(port) -> {:ok, port}
      {:error, reason} -> {:error, reason}
    end
  end

  defp docker_write(port, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp docker_close(port, container) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    remove_container(container)
  end

  # Closing the port only kills the `docker run` CLIENT; the container needs
  # its own removal. Async: this is called from the GenServer.
  defp remove_container(container) do
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      Docker.docker(["rm", "-f", container])
    end)

    :ok
  end
end
