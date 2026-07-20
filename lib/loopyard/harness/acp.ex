defmodule Loopyard.Harness.ACP do
  @moduledoc """
  Agent backend that drives a *real* coding harness (Claude Code today, Codex
  next) over the **Agent Client Protocol** instead of reimplementing the agent
  loop. Implements the same `Loopyard.Harness` behaviour as
  `Backend.ClaudeCode`, so the ChatAgent / StreamHandler / multiplayer stack is
  unchanged — only the event *source* differs.

  This is Foundation A of the north-star (issue #3). Host-side today; the
  in-container variant (#5) swaps only the transport `cmd`
  (`docker exec -i <container> <adapter>`), so the harness runs where the code
  lives and native tools work without the MCP filesystem proxy.

  Status: handshake + streamed prompt turns + permission/fs round-trips,
  `session/cancel` interrupt, `session/load` resume, and in-container mode are
  implemented and tested (fake transport + verified against the real adapter).
  **This is the only production backend** (`config :loopyard, :default_harness`).
  Every harness runs inside its container — the container IS the security
  boundary. There is deliberately no host-execution backend: `Harness.Claude`
  (which ran the `claude` CLI as a host subprocess) was deleted. The one
  alternative is `Harness.Fake` for tests.

  System prompt: there is no ACP `append_system_prompt` — the harness reads
  `CLAUDE.md`/`CLAUDE.local.md` from the session cwd (validated). Loopyard's
  agent prompt arrives as the `append_system_prompt` opt, which
  `maybe_install_system_prompt/2` writes into that file.

  MCP servers: Loopyard's control-plane tools reach the in-container harness as
  an HTTP MCP server (`Loopyard.MCP` / `LoopyardWeb.MCP.Server`) — the
  Initializer builds the spec and passes it as `:acp_mcp_servers`, which
  `start_session/1` forwards to the Connection's `session/new` `mcpServers`.

  Known gaps (tracked on #3/#6): mapping Loopyard's tool *policy* (allowed/
  disallowed tools) onto ACP; token-usage surfacing
  (claude-code-acp doesn't expose it, so cost reads $0 — see cost-visibility
  decision); and the human-gated `:ask` permission mode (#7) — today permissions
  are `:auto_allow`, which is *parity* with the ClaudeCode path (it runs with
  `dangerously_skip_permissions`, trusting the container sandbox as the boundary).
  """
  @behaviour Loopyard.Harness

  alias Loopyard.Harness.ACP.{Connection, SystemPrompt}

  @ready_timeout 30_000
  # session/load REPLAYS the whole saved conversation (plus MCP connects)
  # before answering — a long session under machine load takes well past 30s.
  # A flat 30s here was the root of a crash loop: the timeout killed the
  # connection mid-load ("context canceled" in the adapter's stderr), the
  # restart re-attempted the same slow load, forever.
  @resume_ready_timeout 120_000
  @turn_timeout 600_000

  @impl true
  def start_session(opts) do
    runtime = runtime_opts(opts)
    maybe_install_system_prompt(opts, runtime)

    conn_opts =
      [
        resume: Keyword.get(opts, :resume),
        permission_mode: acp_permission_mode(opts),
        # Loopyard's control-plane tools reach the in-container harness as an
        # HTTP MCP server (the Initializer builds this spec for ACP agents). The
        # Connection forwards it verbatim as `session/new`'s `mcpServers`.
        mcp_servers: Keyword.get(opts, :acp_mcp_servers, [])
      ]
      |> Keyword.merge(runtime)
      |> maybe_put(:model, Keyword.get(opts, :model))

    ready_timeout =
      if Keyword.get(opts, :resume), do: @resume_ready_timeout, else: @ready_timeout

    with {:ok, conn} <- Connection.start_link(conn_opts),
         :ok <- await_ready_safe(conn, ready_timeout) do
      {:ok, conn}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # await_ready that can NEVER blow up the caller: a call timeout or a
  # connection that died mid-handshake used to raise an exit that propagated
  # through ChatAgent.init → RestartController → ServiceManager, cascading the
  # whole workspace subtree. A failed handshake is an EXPECTED condition —
  # return {:error, _} and tear the connection (and its in-container adapter)
  # down so nothing lingers.
  defp await_ready_safe(conn, timeout) do
    Connection.await_ready(conn, timeout)
  catch
    :exit, _ ->
      stop_quiet(conn)
      {:error, :handshake_timeout}
  end

  defp stop_quiet(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :shutdown, 2_000)
  catch
    :exit, _ -> :ok
  end

  # Loopyard's agent system prompt reaches the harness via CLAUDE.local.md in
  # the cwd (claude-code-acp has no append_system_prompt). Host mode writes it
  # directly; in-container mode must write the same file into the code volume
  # (deferred until that path can be validated end to end).
  defp maybe_install_system_prompt(opts, runtime) do
    # Initializer passes Loopyard's agent prompt as `append_system_prompt` (the
    # ClaudeCode/SDK key). ACP has no such option, so install it as CLAUDE.local.md
    # in the cwd. Read either key so the prompt actually reaches the harness —
    # reading only `:system_prompt` silently dropped it (gap #17).
    prompt = Keyword.get(opts, :system_prompt) || Keyword.get(opts, :append_system_prompt)
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
  # Handshake budget (must stay in sync with @resume_ready_timeout above): the
  # longest a legitimate in-flight adapter can still be handshaking. The orphan
  # reaper NEVER touches a process younger than this, so it can't kill a live
  # adapter mid-handshake.
  @reap_min_age_s 150

  def docker_exec_cmd(container, adapter \\ "claude-code-acp") do
    # Launch the adapter through an in-container shell that sources ~/.profile, so
    # the identity env (CLAUDE_CODE_OAUTH_TOKEN, written to ~/.loopyard/env and
    # sourced from ~/.profile by Env.sync_home/1) is in scope. A bare
    # `docker exec ... claude-code-acp` would NOT source it → the harness 401s.
    # Single-quoted so $HOME/$$ expand in the CONTAINER, not on the host.
    #
    # ORPHAN REAP — bounded, AGE-GUARDED. Killing the host-side `docker exec`
    # client on teardown never kills the process tree INSIDE the container, and
    # killing only the node adapter leaves its `claude` CHILD reparented to init
    # and ALIVE (~186MB each) — across a crash loop these pile up into GBs of
    # anon memory. So each launch sweeps prior claude/adapter processes.
    #
    # But the sweep must NEVER kill a legitimately in-flight adapter, or two
    # overlapping (re)starts murder each other (the exit-137 loop). The guard is
    # AGE: only processes older than @reap_min_age_s (> the handshake budget)
    # are reaped. A live handshake is always younger, so it is untouchable; a
    # genuine orphan from a prior turn is always older, so it gets reaped. Age
    # comes from field 22 (starttime, in USER_HZ=100 ticks) of /proc/PID/stat vs
    # /proc/uptime — read with `cut` (comm has no spaces for node/claude, so
    # field indexing is stable). No `||` in the script: it must not contain the
    # sigil delimiter `|`.
    reap =
      ~S|now=$(cut -d. -f1 /proc/uptime); for d in /proc/[0-9]*; do pid=${d##*/}; | <>
        ~S|if [ "$pid" != "$$" ] && grep -qa claude "$d/cmdline" 2>/dev/null; then | <>
        ~S|st=$(cut -d" " -f22 "$d/stat" 2>/dev/null); if [ -n "$st" ]; then | <>
        "age=$(( now - st/100 )); if [ \"$age\" -gt #{@reap_min_age_s} ]; then " <>
        ~S|kill -9 "$pid" 2>/dev/null; fi; fi; fi; done; |

    inner = reap <> ~S|. "$HOME/.profile" 2>/dev/null; exec | <> adapter

    "docker exec -i #{container} sh -c '#{inner}'"
  end

  # Host mode vs in-container mode (#5). In-container: the adapter runs via
  # `docker exec -i` where the code lives, cwd defaults to /workspace, and we
  # declare NO client fs capability so the harness uses the container's own
  # filesystem natively (validated: docker exec -i transport + handshake work;
  # full prompt/fs validation gated on an in-container inference credential).
  defp runtime_opts(opts) do
    case Keyword.get(opts, :container) do
      nil ->
        # NO CONTAINER = NO LAUNCH. Loopyard runs every harness inside a
        # container — that IS the security boundary. A nil-container path used
        # to spawn `claude-code-acp` on the HOST; that possibility is deleted.
        # The only legitimate nil-container caller is a test injecting a fake
        # :transport (no real process). Anything else is refused, loudly.
        case Keyword.get(opts, :transport) do
          nil ->
            raise "CONTAINMENT: Harness.ACP requires :container. Running the adapter on " <>
                    "the HOST is not permitted — every harness runs inside its container. " <>
                    "(Tests may inject a fake :transport instead.) See docs/SECURITY.md."

          transport ->
            [cwd: Keyword.get(opts, :cwd), client_fs: true, transport: transport]
            |> maybe_put(:transport_opts, Keyword.get(opts, :transport_opts))
        end

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
  def cancel_turn(conn) do
    # Send ACP `session/cancel` to interrupt the in-flight turn while keeping the
    # connection warm. Exit-safe (mirrors Harness.Claude): warm_interrupt treats
    # a non-:ok/timeout as "wedged → hard restart", so a dead conn must not raise.
    if is_pid(conn) and Process.alive?(conn), do: Connection.cancel(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  @doc "Switch the live session's model (ACP session/set_model). Async."
  def set_model(conn, model_id) when is_pid(conn), do: Connection.set_model(conn, model_id)
  def set_model(_conn, _model_id), do: :ok

  @doc "The adapter's model list for a live session: `[%{id, name, description}]`."
  def available_models(conn) when is_pid(conn), do: Connection.available_models(conn)
  def available_models(_conn), do: []

  # Liveness = the HARNESS answers, not merely "our local GenServer exists".
  # The exec client can outlive a dead/wedged in-container adapter (docker
  # daemon hiccup, fd-exhaustion storm) — a bare Process.alive? reported those
  # sessions healthy while every turn timed out, so nothing auto-respawned.
  # Connection.ping round-trips the adapter's event loop; :initializing counts
  # as alive (still booting ≠ dead — don't let a caller double-spawn mid-
  # handshake).
  def session_alive?(conn) do
    is_pid(conn) and Process.alive?(conn) and
      case Connection.ping(conn) do
        :pong -> true
        {:error, :initializing} -> true
        _ -> false
      end
  end

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
