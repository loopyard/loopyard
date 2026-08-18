defmodule Loopyard.StateKeeper do
  @moduledoc """
  Long-lived GenServer that is the sole owner of all shared ETS tables.

  ETS tables die with their owner. Centralizing creation here means:

  1. One place knows every table name and its options.
  2. No races — no other code path calls `:ets.new`, so there's no
     need for `try/catch :error, :badarg` guards elsewhere.
  3. If StateKeeper dies and the supervisor restarts it, every table
     it owned is gone — any process holding a stale reference will
     crash on next access and be restarted by its own supervisor.
     That's the intended blast radius; don't hot-restore tables.

  Start this process EARLY in the application supervisor, before any
  module that reads from these tables.
  """
  use GenServer

  @tables [
    {:chat_agents, [:named_table, :public, :set]},
    # Outstanding CARD-STATE patches (question drafts/answers, approval and
    # secret status flips) applied to the ETS summary ahead of the owning
    # GenServer's mailbox. summary/1 re-applies them so a busy agent's stale
    # summary write can never CLOBBER a card interaction the user just made
    # (the check appearing then vanishing read as "questions are busted").
    # Keyed {agent_id, msg_id}; the agent deletes on convergence.
    {:card_patches, [:named_table, :public, :set]},
    # Loopyard.MCP.Token revocation epochs, keyed by agent_id. A token embeds
    # the agent's epoch at mint time; verify rejects a token whose epoch is
    # below the current one. Revoking (agent death / workspace delete) bumps
    # the epoch, so outstanding tokens for that agent stop verifying. Cleared
    # on restart (agents/containers are torn down then anyway).
    {:mcp_token_epochs, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Markdown render cache, keyed by content. Chat bubbles render
    # Markdown server-side; without this, LiveView re-runs MDEx for every
    # visible bubble on every chat re-render (hundreds per streaming turn),
    # starving the LV process and timing out user sends. Content is immutable,
    # so a hit is always correct. Read-heavy; reads go direct.
    {:markdown_cache, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:project_registry, [:named_table, :public, :set]},
    {:workspace_registry, [:named_table, :public, :set]},
    {:event_log, [:named_table, :public, :ordered_set]},
    {:service_status_cache, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Workspace.LogBuffer — a persistent ring buffer of streamed service
    # log frames, keyed by {workspace_id, service_name}. Survives the container
    # dying, so a crashed service's output is still readable. Written by the
    # per-workspace LogBuffer GenServer; the UI reads direct.
    {:service_log_frames, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:docker_observer, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:loopyard_evals, [:named_table, :public, :set]},
    # Loopyard.PortRegistry entries keyed by {workspace_id, service, container_port}.
    # Writes serialize through the PortRegistry GenServer; reads go direct.
    {:port_registry, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Harness.Questions — pending harness→user questions keyed by
    # question_id. The asking process (an MCP tool / ACP connection) blocks on
    # receive; the UI's answer delivers via the stored waiter pid. Public set.
    {:harness_questions, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Harness.Approvals — pending boundary-crossing action proposals
    # (fork/integrate) awaiting a human approve/deny, keyed by approval_id. Same
    # blocking-waiter pattern as :harness_questions.
    {:harness_approvals, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Harness.SecretRequests — pending agent secret requests awaiting a
    # human-submitted value, keyed by request_id. Same blocking-waiter pattern as
    # :harness_questions; the secret VALUE is never stored here (it goes straight
    # to the on-disk secret store from the LiveView).
    {:secret_requests, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.ChangeCounts — cached per-workspace changed-file counts
    # ({workspace_id, count, computed_at}) so overview surfaces show ±N with
    # zero render-time git shell-outs. Written by ChangeCounts' async
    # recomputes; WorkspaceTree reads direct.
    {:ws_change_counts, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Operator.Digest — a bounded ring of cross-workspace turn
    # completions ({seq, entry}), so the operator can PULL "what finished"
    # (recent_activity tool) without any of it living in its LLM context.
    # ordered_set keyed by a monotonic seq; the Digest GenServer writes, the
    # tool reads direct.
    {:operator_digest, [:named_table, :public, :ordered_set, {:read_concurrency, true}]},
    # Loopyard.Operator.Jobs — the operator's WORKER QUEUE. One entry per
    # workspace you've dispatched work to ({ws_id, %{agent_id, read_count}}). The
    # "delta since you last looked" = current msg count − read_count; dive-in /
    # dispatch re-anchors read_count. Written by the Jobs API; the queue reads direct.
    {:operator_jobs, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Ring buffer for Loopyard.Events.Tap — every broadcast on every
    # known topic. ordered_set keyed by a monotonic counter so the
    # newest records come out with a single :ets.select_reverse.
    # Plan: Move #7.
    {:events_tap, [:named_table, :public, :ordered_set, {:read_concurrency, true}]},
    # Loopyard.Resources.Janitor — tracked OS/OTP resources keyed
    # by {kind, id}. Reads go direct for list_for_owner / all; writes
    # serialize through the Janitor GenServer so the owner-index and
    # monitor refs stay consistent. Plan: Move #7b.
    {:resource_registry, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.ChatAgent.RestartController crash history keyed by
    # {workspace_id, agent_id}. Lives here so that when WorkspaceGroup
    # restarts the RestartController (via :one_for_all on any sibling
    # crash), the crash counters survive — otherwise quarantine gets
    # reset and an agent that was 4-of-5 crashes resets to 0-of-5.
    # Move #10 bug fix (audit item HIGH #3).
    {:restart_controller_history, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.Saga.Recorder — last 100 saga run records keyed by
    # saga_id. Previously created in Recorder.init/1 directly, which
    # violated the "StateKeeper is the sole ETS owner" invariant and
    # meant a Recorder crash dropped every recorded saga. Owned here
    # now so recovery is trivial. Audit item MEDIUM #10.
    {:saga_recorder, [:named_table, :public, :set, {:read_concurrency, true}]},
    # Loopyard.LogBuffer — rolling log tail surfaced on /system.
    # Moved here from LogBuffer.init/1 for the same reason as
    # :saga_recorder: StateKeeper is sole ETS owner so buffered logs
    # survive a LogBuffer GenServer crash. Audit-2 MEDIUM #6.
    {:log_buffer, [:named_table, :public, :set]},
    # Loopyard.WindowViews — per-window "where was I": the last view (path) each
    # browser window was on in each workspace, so the switcher resumes there.
    # Keyed by {transport_pid, workspace_id} — per LiveView connection (window),
    # so two windows don't clobber each other. Server-side, node-local.
    {:window_views, [:named_table, :public, :set, {:read_concurrency, true}]}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Idempotently ensure all tables exist. Safe to call from tests that
  start this module manually. In a running application the tables are
  created in `init/1` and this is a no-op.
  """
  def ensure_tables! do
    Enum.each(@tables, fn {name, opts} ->
      if :ets.whereis(name) == :undefined do
        :ets.new(name, opts)
      end
    end)

    :ok
  end

  @impl true
  def init(:ok) do
    ensure_tables!()
    Loopyard.EventLog.info("system", "Loopyard started")
    {:ok, %{}}
  end

  # Catchalls. StateKeeper owns every named ETS table in the system
  # (see @tables). If this GenServer crashes, every table dies with
  # it and every subsystem that reads/writes ETS gets :noexit on its
  # next access. A stray message — a monitor DOWN, a node up/down, a
  # stale cast from a renamed caller — must NEVER be able to take it
  # down. All three callback catchalls absorb unknowns into telemetry.
  require Logger

  @impl true
  def handle_info(msg, state) do
    Logger.warning("[StateKeeper] unhandled info: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, kind: :info, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.warning("[StateKeeper] unhandled cast: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, kind: :cast, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(msg, _from, state) do
    Logger.warning("[StateKeeper] unhandled call: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, kind: :call, msg: inspect(msg, limit: 200)}
    )

    {:reply, {:error, :unknown_call}, state}
  end

  def put_eval(name, info), do: :ets.insert(:loopyard_evals, {name, info})

  def get_eval(name) do
    case :ets.lookup(:loopyard_evals, name) do
      [{^name, info}] -> info
      _ -> nil
    end
  end

  def list_evals, do: :ets.tab2list(:loopyard_evals)
end
