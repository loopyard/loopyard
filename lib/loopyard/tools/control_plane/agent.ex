defmodule Loopyard.Tools.ControlPlane.Agent do
  @moduledoc """
  The operator's agent-control tool — the "keep the fleet moving / unstick things"
  hands. One verb, an `action`, so the tool count stays lean:

    * interrupt — stop a runaway/wedged agent's current turn
    * restart   — restart a stalled agent's session (conversation kept) — the
      literal "prevent agents from being stalled" lever
    * wake      — start a stopped/asleep agent
    * new       — spawn a NEW agent in the target workspace (parallel work),
      optionally on a named `account` and `model`
    * switch    — move an agent onto another `account` and/or `model` (a
      `harness:model` selection). The lever for "this account hit its limit" or
      "this is cheap work, run it on a smaller model": the conversation is
      carried over from Loopyard's log either way. `subagent_model` sets
      what the agent's OWN sub-agents run on (a model id, or `same` to clear)
      — a capable main model directing cheaper workers.

  `target` is a workspace id/name or an agent id. Guarded so the operator can't
  interrupt/restart/switch ITSELF.
  """
  use Loopyard.Tool,
    name: "agent",
    description:
      "Control a workspace's agent to keep things moving. action=interrupt stops " <>
        "its current turn; action=restart un-sticks a wedged/stalled session " <>
        "(conversation kept); action=wake starts a stopped/asleep agent; " <>
        "action=new spawns a NEW agent in the target workspace (optional `message` " <>
        "= its first task, optional `account` / `model`); action=switch moves an " <>
        "agent onto another `account` (when its account is rate-limited or its " <>
        "sign-in expired) and/or another `model` and/or `subagent_model` (what its " <>
        "own sub-agents run on) — the conversation carries over. " <>
        "`overview` lists the accounts and what each can run. `target` is a " <>
        "workspace id/name or an agent id.",
    busy_words: ["managing an agent"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name or agent id."},
      action: {:string, required: true, description: "interrupt | restart | wake | new | switch"},
      message:
        {:string, description: "For action=new only: the new agent's first task (optional)."},
      account:
        {:string,
         description:
           "For action=switch/new: the account (workstation id) to run under — see overview's Accounts line."},
      model:
        {:string,
         description:
           "For action=switch/new: a `harness:model` selection, e.g. `claude:claude-sonnet-5` or `codex:default`."},
      subagent_model:
        {:string,
         description:
           "For action=switch: the model id the agent's own sub-agents run on, e.g. `claude-sonnet-5`, or `same` for the agent's own model."}
    ]

  alias Loopyard.{ChatAgent, Tools.ControlPlane, Workstation}
  alias Loopyard.Harness.Catalog

  def execute(%{agent_id: operator_id, target: target} = params, _assigns) do
    case (params[:action] || "") |> to_string() |> String.downcase() do
      "new" ->
        spawn_new(target, params)

      "switch" ->
        switch(target, params, operator_id)

      a when a in ["interrupt", "restart", "wake"] ->
        control(target, a, operator_id)

      other ->
        {:error, "Unknown action '#{other}'. Use interrupt, restart, wake, new, or switch."}
    end
  rescue
    e -> {:error, "agent action failed: #{inspect(e)}"}
  end

  defp control(target, action, operator_id) do
    with {:ok, agent} <- ControlPlane.resolve_agent(target) do
      cond do
        agent.id == operator_id ->
          {:error, "That resolves to the operator itself — target a WORKSPACE agent."}

        action == "interrupt" ->
          ChatAgent.interrupt(agent.id)
          {:ok, "Interrupted #{agent.name} (#{agent.id}) — its current turn is stopping."}

        action == "restart" ->
          ChatAgent.restart_session(agent.id, :reload)
          {:ok, "Restarting #{agent.name} (#{agent.id}) — fresh session, conversation kept."}

        action == "wake" ->
          ChatAgent.start_agent(agent.id)
          {:ok, "Woke #{agent.name} (#{agent.id})."}
      end
    end
  end

  defp spawn_new(target, params) do
    message = params[:message]

    with {:ok, ws_id} <- ControlPlane.resolve_workspace(target),
         {:ok, selection} <- selection(params[:model]),
         harness = selection && elem(selection, 0),
         {:ok, account} <- account(params[:account], harness) do
      opts =
        [started_by: "operator"] ++
          if(is_binary(message) and String.trim(message) != "",
            do: [initial_message: message],
            else: []
          ) ++
          if(account, do: [workstation_identity: account], else: []) ++
          case selection do
            {h, nil} -> [harness: h]
            {h, m} -> [harness: h, model: m]
            nil -> []
          end

      case Loopyard.Onboarding.spawn_agent(ws_id, opts) do
        {:ok, aid} -> {:ok, "Spawned a new agent (#{aid}) in workspace #{ws_id}."}
        {:error, r} -> {:error, "Couldn't spawn an agent: #{inspect(r)}"}
      end
    end
  end

  # Move an agent onto another account and/or model. Both go through the same
  # entry points the sidebar pickers use, so the restart reason, the dropped
  # native session and the reseed from Loopyard's log are identical.
  defp switch(target, params, operator_id) do
    with {:ok, agent} <- ControlPlane.resolve_agent(target),
         :ok <- not_self(agent, operator_id),
         {:ok, selection} <- selection(params[:model]),
         harness = (selection && elem(selection, 0)) || agent[:harness] || Catalog.default(),
         {:ok, account} <- account(params[:account], harness),
         {:ok, subagents} <- subagents(params[:subagent_model], harness) do
      if is_nil(selection) and is_nil(account) and is_nil(subagents) do
        {:error, "Nothing to switch — pass `account`, `model` and/or `subagent_model`."}
      else
        done =
          [
            switch_model(agent, selection),
            switch_account(agent, account),
            switch_subagents(agent, subagents)
          ]
          |> Enum.filter(& &1)
          |> Enum.join(" and ")

        {:ok,
         "#{agent.name} (#{agent.id}) is moving to #{done} — it restarts and picks its " <>
           "conversation back up."}
      end
    end
  end

  defp not_self(%{id: id}, id),
    do: {:error, "That resolves to the operator itself — target a WORKSPACE agent."}

  defp not_self(_agent, _operator_id), do: :ok

  defp switch_model(_agent, nil), do: nil

  defp switch_model(agent, {harness, model}) do
    if harness == (agent[:harness] || Catalog.default()) do
      if model, do: ChatAgent.set_model(agent.id, model)
    else
      ChatAgent.set_harness(agent.id, harness, model)
    end

    "#{Catalog.label(harness)} #{model || "default"}"
  end

  defp switch_account(_agent, nil), do: nil

  defp switch_account(agent, account) do
    ChatAgent.set_workstation(agent.id, account)
    "account #{account}"
  end

  defp switch_subagents(_agent, nil), do: nil

  defp switch_subagents(agent, {:set, model}) do
    ChatAgent.set_subagent_model(agent.id, model)
    "sub-agents on #{model || "the agent's own model"}"
  end

  # nil = not asked for; `same` (or "") clears it. Validated against the
  # harness the agent will run on — a harness without the knob refuses.
  defp subagents(nil, _harness), do: {:ok, nil}

  defp subagents(value, harness) when is_binary(value) do
    value = String.trim(value)

    cond do
      not Catalog.subagent_model?(harness) ->
        {:error, "#{Catalog.label(harness)} doesn't take a sub-agent model."}

      value in ["", "same", "inherit"] ->
        {:ok, {:set, nil}}

      Catalog.subagent_model_valid?(harness, value) ->
        {:ok, {:set, value}}

      true ->
        {:error,
         "subagent_model must be one of " <>
           Enum.map_join(Catalog.fetch(harness).models, ", ", &elem(&1, 0)) <>
           ", or `same` — got '#{value}'."}
    end
  end

  defp subagents(_, _), do: {:error, "subagent_model must be a model id or `same`."}

  # nil = not asked for. A selection must parse — never guess a harness.
  defp selection(nil), do: {:ok, nil}

  defp selection(value) when is_binary(value) do
    case Catalog.parse_selection(String.trim(value)) do
      {:ok, harness, model} ->
        {:ok, {harness, model}}

      :error ->
        {:error,
         "model must be a `harness:model` selection (e.g. claude:claude-sonnet-5, " <>
           "codex:default) — got '#{value}'."}
    end
  end

  defp selection(_), do: {:error, "model must be a `harness:model` selection."}

  # An account must exist AND hold a credential for the harness it would run:
  # switching onto one that can't sign in strands the agent.
  defp account(nil, _harness), do: {:ok, nil}

  defp account(id, harness) when is_binary(id) do
    id = String.trim(id)

    cond do
      not Workstation.exists?(id) ->
        {:error, "No account '#{id}'. #{known_accounts()}"}

      not Catalog.credentialed?(harness, Workstation.Env.all(id)) ->
        {:error,
         "Account '#{id}' has no #{Catalog.label(harness)} credential — it must be signed " <>
           "in first (its workstation page). #{known_accounts()}"}

      true ->
        {:ok, id}
    end
  end

  defp account(_, _), do: {:error, "account must be a workstation id."}

  defp known_accounts do
    "Accounts: " <>
      Enum.map_join(Workstation.accounts(), "; ", fn %{id: id, harnesses: hs} ->
        "#{id} (#{Enum.map_join(hs, ", ", &Catalog.label/1)})"
      end) <> "."
  rescue
    _ -> ""
  end
end
