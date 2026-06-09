defmodule Loopyard.Agent.Backend.ACP do
  @moduledoc """
  Agent backend that drives a *real* coding harness (Claude Code today, Codex
  next) over the **Agent Client Protocol** instead of reimplementing the agent
  loop. Implements the same `Loopyard.Agent.Backend` behaviour as
  `Backend.ClaudeCode`, so the ChatAgent / StreamHandler / multiplayer stack is
  unchanged — only the event *source* differs.

  This is Foundation A of the north-star (issue #3). Host-side today; the
  in-container variant (#5) swaps only the transport `cmd`
  (`docker exec -i <container> <adapter>`), so the harness runs where the code
  lives and native tools work without the MCP filesystem proxy.

  Status: handshake + streamed prompt turns + permission/fs round-trips and
  in-container mode are implemented and tested (fake transport + verified
  against the real adapter). Not yet wired as the default backend.

  System prompt: there is no ACP `append_system_prompt` — the harness reads
  `CLAUDE.md` from the session cwd (validated), so `ChatAgent.ClaudeContext.mirror/2`
  is the mechanism; wiring writes Loopyard's agent prompt into that file.

  Known gaps (tracked on #3/#6): mapping Loopyard's tool *policy* onto ACP,
  token-usage surfacing (claude-code-acp doesn't expose it — see cost-visibility
  decision), and the `:ask` permission mode (#7).
  """
  @behaviour Loopyard.Agent.Backend

  alias Loopyard.Agent.Backend.ACP.{Connection, SystemPrompt}

  @ready_timeout 30_000
  @turn_timeout 600_000

  @impl true
  def start_session(opts) do
    runtime = runtime_opts(opts)
    maybe_install_system_prompt(opts, runtime)

    conn_opts =
      [
        resume: Keyword.get(opts, :resume),
        permission_mode: acp_permission_mode(opts)
      ]
      |> Keyword.merge(runtime)
      |> maybe_put(:model, Keyword.get(opts, :model))

    with {:ok, conn} <- Connection.start_link(conn_opts),
         :ok <- Connection.await_ready(conn, @ready_timeout) do
      {:ok, conn}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Loopyard's agent system prompt reaches the harness via CLAUDE.local.md in
  # the cwd (claude-code-acp has no append_system_prompt). Host mode writes it
  # directly; in-container mode must write the same file into the code volume
  # (deferred until that path can be validated end to end).
  defp maybe_install_system_prompt(opts, runtime) do
    prompt = Keyword.get(opts, :system_prompt)
    cwd = Keyword.get(runtime, :cwd)
    container? = not is_nil(Keyword.get(opts, :container))

    if is_binary(prompt) and prompt != "" and is_binary(cwd) and not container? do
      SystemPrompt.install(cwd, prompt)
    end

    :ok
  end

  @doc """
  The `docker exec -i` command that runs the ACP adapter inside a container —
  the in-container variant of the transport (#5). Only this string differs from
  host mode; the protocol/connection layer is identical.
  """
  def docker_exec_cmd(container, adapter \\ "claude-code-acp") do
    "docker exec -i #{container} #{adapter}"
  end

  # Host mode vs in-container mode (#5). In-container: the adapter runs via
  # `docker exec -i` where the code lives, cwd defaults to /workspace, and we
  # declare NO client fs capability so the harness uses the container's own
  # filesystem natively (validated: docker exec -i transport + handshake work;
  # full prompt/fs validation gated on an in-container inference credential).
  defp runtime_opts(opts) do
    case Keyword.get(opts, :container) do
      nil ->
        [cwd: Keyword.get(opts, :cwd), client_fs: true]
        |> maybe_put(:transport, Keyword.get(opts, :transport))
        |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))

      container ->
        base = [cwd: Keyword.get(opts, :cwd, "/workspace"), client_fs: false]

        case Keyword.get(opts, :transport) do
          # Tests can inject a fake transport even in container mode.
          nil ->
            adapter = Keyword.get(opts, :adapter, "claude-code-acp")
            Keyword.put(base, :transport_opts, cmd: docker_exec_cmd(container, adapter))

          transport ->
            base
            |> Keyword.put(:transport, transport)
            |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))
        end
    end
  end

  @impl true
  def stream(conn, prompt) do
    Stream.resource(
      fn ->
        ref = make_ref()
        Connection.prompt(conn, prompt, self(), ref)
        ref
      end,
      fn ref ->
        receive do
          {:acp_event, ^ref, event} -> {[event], ref}
          {:acp_done, ^ref, _stop} -> {:halt, ref}
        after
          @turn_timeout -> {:halt, ref}
        end
      end,
      fn _ref -> :ok end
    )
  end

  @impl true
  def stop(conn) do
    if is_pid(conn) and Process.alive?(conn), do: Connection.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def session_alive?(conn), do: is_pid(conn) and Process.alive?(conn)

  @impl true
  def session_id(conn) do
    if is_pid(conn) and Process.alive?(conn), do: Connection.session_id(conn)
  end

  # Loopyard's :accept_edits / dangerously_skip_permissions map to auto-allow
  # for now; the #7 work introduces an :ask mode that blocks on a UI decision.
  defp acp_permission_mode(_opts), do: :auto_allow

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
