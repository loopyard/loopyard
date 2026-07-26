defmodule Loopyard.Harness.Approvals do
  @moduledoc """
  The human-approval broker for boundary-crossing actions (fork / integrate /
  delete a workspace, create a project — the "agent spawned a shitload of
  workspaces" guardrail).

  Two modes, both post a `role: :approval` message (persisted + broadcast → the
  whole room sees the Approve/Deny card):

  ## Queued (default — `post/2` + `run/3`)

  The agent calls a tool (`propose_fork`) which calls `post/2` and returns
  **immediately** — the agent's turn ends with "proposed X, awaiting your
  approval." The card carries the full `action` map, so it's durable: it stays
  `:pending` with **no TTL** and survives restarts. Whenever a human clicks
  Approve, the LiveView runs `run/3`, which executes the action from the
  persisted card and `resolve/3`s it (progress → terminal status). Nothing
  blocks a turn, so a slow human can't trip the stream safety timer and no
  approval ever silently "times out." This is the path for every workspace
  action (fork / integrate / delete).

  ## Blocking (legacy — `request/2` + `decide/2`)

  Same blocking-waiter pattern as `Loopyard.Harness.Questions`: `request/2`
  BLOCKS the tool call until `decide/2` delivers the human's choice (30-min TTL).
  Still used by the operator's `create_project` flow (`Tools.ControlPlane`),
  whose creation is a runtime closure that can't live in a persisted card.
  Migrating it to the queued model (serialize the project spec) is a follow-up.

  Either way, `resolve/3` flips the card to its outcome (`:approved` /
  `:integrated` / `:denied` / `:failed`), persisted + broadcast to everyone.
  """
  alias Loopyard.ChatAgent

  @table :harness_approvals
  @timeout_ms 30 * 60 * 1000

  # --- Queued model (post + run) — no TTL, no blocked turn ---

  @doc """
  Post an approval card for `action` and return immediately (the queued model).
  The card is `:pending` with the full `action` embedded, so the decision can be
  acted on later via `run/3` — there's no waiter and no TTL. Returns `:ok`.
  """
  @spec post(String.t(), map()) :: :ok
  def post(agent_id, action) when is_binary(agent_id) and is_map(action) do
    ChatAgent.append_message_ets(agent_id, %{
      role: :approval,
      approval_id: gen_id(),
      action: action,
      status: :pending,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  @doc """
  Execute an approved action from its persisted card. Called from the LiveView's
  approve handler (off the socket, in a Task) — NOT from the agent's turn. Runs
  the fork/integrate/delete, streaming progress into the card via `resolve/3` and
  flipping it to its terminal status. Safe to run detached: it needs only the
  `action` map (durable in the card) and `msg_id` (the card's message id).
  """
  @spec run(String.t(), String.t() | nil, map()) :: :ok
  def run(agent_id, msg_id, %{verb: :rename_project} = action) do
    case Loopyard.ProjectRegistry.rename_project(action.project_id, action.name) do
      {:ok, _} -> resolve(agent_id, msg_id, %{status: :renamed})
      {:error, reason} -> resolve(agent_id, msg_id, %{status: :failed, error: inspect(reason)})
    end

    :ok
  end

  def run(agent_id, msg_id, %{verb: :rename_workspace} = action) do
    Loopyard.WorkspaceRegistry.update_setup(action.workspace_id, %{name: action.name})
    resolve(agent_id, msg_id, %{status: :renamed})
    :ok
  end

  def run(agent_id, msg_id, %{verb: :fork} = action) do
    resolve(agent_id, msg_id, %{status: :creating, detail: "Starting…"})
    progress = fn step -> resolve(agent_id, msg_id, %{status: :creating, detail: step}) end

    # Copy THIS workspace (working tree + .loopyard infra), forked onto the new
    # branch — the source ws id rides in the action so this runs without the
    # proposing agent's live state. `base` is just the card label.
    case Loopyard.Onboarding.fork_from_workspace(
           action.project_id,
           action.workspace_id,
           action.branch,
           progress
         ) do
      {:ok, new_ws} ->
        progress.("Starting the agent…")

        new_agent_id =
          case Loopyard.Onboarding.spawn_agent(new_ws.id, started_by: "fork") do
            {:ok, aid} -> aid
            _ -> nil
          end

        resolve(agent_id, msg_id, %{
          status: :approved,
          workspace_id: new_ws.id,
          project_id: action.project_id,
          agent_id: new_agent_id
        })

      {:error, reason} ->
        resolve(agent_id, msg_id, %{status: :failed, error: inspect(reason)})
    end

    :ok
  end

  def run(agent_id, msg_id, %{verb: :integrate} = action) do
    resolve(agent_id, msg_id, %{status: :integrating})

    # Resolve the GitHub URL + token HERE (approve time), not in the durable
    # card — so the token never lands in the persisted approval message. A
    # GitHub-backed project lands on GitHub main; a local-only one (nil url)
    # falls back to the legacy canonical path inside integrate/5.
    github_url = integrate_remote(action.project_id)
    token = integrate_token(action.workspace_id)

    result =
      Loopyard.CanonicalRepo.integrate(
        action.project_id,
        action.workspace_id,
        action.branch,
        github_url,
        token: token
      )

    case result do
      {:ok, _} -> resolve(agent_id, msg_id, %{status: :integrated})
      {:error, reason} -> resolve(agent_id, msg_id, %{status: :failed, error: inspect(reason)})
    end

    :ok
  end

  def run(_agent_id, _msg_id, %{verb: :delete_workspace} = action) do
    # Deleting the workspace destroys this agent (and its message log), so there's
    # no card left to resolve — the LiveView has already navigated the human away.
    # Just do the teardown.
    Loopyard.Workspace.Destructor.destroy(action.workspace_id)
    :ok
  end

  def run(_agent_id, _msg_id, _action), do: :ok

  # --- Blocking model (request + decide) — operator create_project only ---

  @doc """
  Post an approval card for `action` and BLOCK until a human decides. Returns
  `{:approve | :deny | :timeout, msg_id}` — `msg_id` lets the caller `resolve/3`
  the card with the outcome.
  """
  @spec request(String.t(), map()) :: {:approve | :deny | :timeout, String.t() | nil}
  def request(agent_id, action) when is_binary(agent_id) and is_map(action) do
    id = gen_id()

    msg =
      ChatAgent.append_message_ets(agent_id, %{
        role: :approval,
        approval_id: id,
        action: action,
        status: :pending,
        timestamp: DateTime.utc_now()
      })

    msg_id = msg && msg.id
    :ets.insert(@table, {id, %{agent_id: agent_id, msg_id: msg_id, waiter: self()}})

    receive do
      {:decided, ^id, decision} ->
        :ets.delete(@table, id)
        {decision, msg_id}
    after
      @timeout_ms ->
        :ets.delete(@table, id)
        {:timeout, msg_id}
    end
  end

  @doc """
  Deliver a human's approve/deny. Called from the LiveView. If the waiter
  (the blocked `propose_*` tool process) has died, the decision can't be
  delivered — reap the leaked entry, flip the card to `:timeout`, and return
  `{:error, :not_found}` instead of silently sending to a dead pid.
  """
  @spec decide(String.t(), :approve | :deny) :: :ok | {:error, :not_found}
  def decide(id, decision) when is_binary(id) and decision in [:approve, :deny] do
    case :ets.lookup(@table, id) do
      [{^id, %{waiter: pid}}] when is_pid(pid) ->
        if Process.alive?(pid) do
          send(pid, {:decided, id, decision})
          :ok
        else
          reap(id)
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  The pending approval for `agent_id`, if any: `{id, entry}` or `nil`. An agent
  blocks on at most one `propose_*` call at a time, so there's one entry to
  find. If the waiter died abnormally (session restart, stream replaced, CLI
  crash) the receive in `request/2` never ran and the entry leaked — reap it
  here and flip the card off "Pending…" so a dead approval can't spin forever.
  """
  @spec pending_for_agent(String.t()) :: {String.t(), map()} | nil
  def pending_for_agent(agent_id) when is_binary(agent_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, entry} -> entry.agent_id == agent_id end)
    |> Enum.find_value(fn {id, entry} ->
      if Process.alive?(entry.waiter) do
        {id, entry}
      else
        reap(id, entry)
        nil
      end
    end)
  end

  @doc "Whether `agent_id` is currently blocked awaiting an approval decision."
  @spec pending_for_agent?(String.t()) :: boolean()
  def pending_for_agent?(agent_id), do: pending_for_agent(agent_id) != nil

  @doc """
  Every live BLOCKING approval across all agents — for the town-hall line. Only
  the blocking path (`request/2`) lands in this table; queued `propose_*` cards
  live in the message stream (see `pending_in_messages?/1`). Reaps dead waiters
  as it scans.
  """
  @spec pending_all() :: [{String.t(), map()}]
  def pending_all do
    :ets.tab2list(@table)
    |> Enum.filter(fn {id, entry} ->
      if Process.alive?(entry.waiter) do
        true
      else
        reap(id, entry)
        false
      end
    end)
  end

  @doc """
  Whether a message list carries an unresolved approval card. The QUEUED path
  (`post/2` — every workspace fork/integrate/delete) deliberately does NOT
  insert into this module's ETS table (nothing blocks on it), so
  `pending_for_agent?/1` can't see those; the pending card lives only in the
  agent's message stream. Overview surfaces (WorkspaceTree) scan the summary's
  message list with this instead — an in-memory `any?` over ≤1000 small maps
  (resolved cards get `status` rewritten in place, so :pending means live).
  """
  @spec pending_in_messages?(list()) :: boolean()
  def pending_in_messages?(messages) when is_list(messages) do
    Enum.any?(messages, fn
      %{role: :approval, status: :pending} -> true
      _ -> false
    end)
  end

  def pending_in_messages?(_), do: false

  @doc "Update the approval card with the outcome (persisted + broadcast)."
  @spec resolve(String.t(), String.t() | nil, map()) :: :ok
  def resolve(_agent_id, nil, _changes), do: :ok

  def resolve(agent_id, msg_id, changes) do
    ChatAgent.update_message(agent_id, msg_id, fn m -> Map.merge(m, changes) end)
    :ok
  end

  @spec pending?(String.t()) :: boolean()
  def pending?(id), do: :ets.member(@table, id)

  # --- internals ---

  # The project's GitHub remote (or nil for local-only).
  defp integrate_remote(project_id) do
    case Loopyard.ProjectRegistry.get_project(project_id) do
      %{source_config: %{remote: remote}} when is_binary(remote) and remote != "" -> remote
      _ -> nil
    end
  end

  # A token that can push to the project's GitHub repo: the workspace identity's
  # GITHUB_TOKEN first, else the host `gh auth token` (same source the initial
  # clone uses). Injected host-side into a throwaway URL; never persisted.
  defp integrate_token(workspace_id) do
    identity_token =
      case Loopyard.Workspace.workstation_id(workspace_id) do
        id when is_binary(id) -> Loopyard.Workstation.Env.all(id)["GITHUB_TOKEN"]
        _ -> nil
      end

    identity_token || Loopyard.Tools.ControlPlane.github_token()
  end

  # Reap a leaked entry (waiter dead): drop it from ETS and flip the card off
  # "Pending…" so it can't spin forever.
  defp reap(id) do
    case :ets.lookup(@table, id) do
      [{^id, entry}] -> reap(id, entry)
      _ -> :ok
    end
  end

  defp reap(id, entry) do
    :ets.delete(@table, id)
    resolve(entry.agent_id, entry.msg_id, %{status: :timeout})
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
