defmodule Loopyard.WorkspaceTree.Headline do
  @moduledoc """
  ONE priority-ordered headline for a workspace — the overview's answer to
  "what does this need from me / what's happening": needs-you > broken >
  working > changed > quiet.

  Pure over the `WorkspaceTree` workspace shape (`:needs_you`, `:broken`,
  `:agents`, `:changes`). Returns `%{kind, text}` (plus `added`/`removed` for
  `:changed`) or nil for quiet (ready / asleep — a status dot carries those;
  no redundant status words). The text always says something NEW (what it
  wants, what broke, what it's doing) — never the color-word.

  This lives in the domain, not the web layer, because the operator's working
  list (`Loopyard.Operator.Queue`) derives its state from it too. The web
  component (`LoopyardWeb.Components.Birdseye.headline/1`) wraps this and adds
  the colour class — presentation stays in the component, meaning stays here.
  """

  alias Loopyard.Agent.ToolKind

  # Agent statuses that count as "working" — mirrors the rail's dot semantics.
  @working [:thinking, :compacting, :booting, :backoff, :rate_limited]

  @type kind :: :needs_you | :broken | :working | :changed
  @type t ::
          %{kind: kind(), text: String.t()}
          | %{
              kind: :changed,
              text: String.t(),
              added: non_neg_integer(),
              removed: non_neg_integer()
            }

  @doc "Agent statuses the headline treats as working."
  @spec working_statuses() :: [atom()]
  def working_statuses, do: @working

  @doc "The workspace's headline, or nil when it's quiet."
  @spec headline(map()) :: t() | nil
  def headline(ws) do
    agents = ws[:agents] || []

    cond do
      kind = ws[:needs_you] ->
        %{kind: :needs_you, text: needs_you_text(kind)}

      kind = ws[:broken] ->
        %{kind: :broken, text: broken_text(kind)}

      working = Enum.find(agents, &(Map.get(&1, :status) in @working)) ->
        %{kind: :working, text: working_text(working)}

      match?(%{added: _, removed: _}, ws[:changes]) and
          ws[:changes].added + ws[:changes].removed > 0 ->
        # Carry the raw +/- so every surface can render the green/red split
        # (ProjectList.change_stat). `text` stays as a single-string fallback
        # for anywhere that only reads text.
        %{
          kind: :changed,
          added: ws[:changes].added,
          removed: ws[:changes].removed,
          text: "+#{ws[:changes].added} −#{ws[:changes].removed}"
        }

      true ->
        nil
    end
  end

  defp needs_you_text(:question), do: "asked a question"
  defp needs_you_text(:approval), do: "wants approval"
  defp needs_you_text(:secret), do: "needs a secret"
  defp needs_you_text(_), do: "needs you"

  defp broken_text(:auth_expired), do: "sign in again"
  defp broken_text(:quarantined), do: "crash-looping"
  defp broken_text(:service_crashed), do: "service crashed"
  defp broken_text(_), do: "broken"

  # What the working agent is doing, in the READER's words — never the raw tool
  # name. Printing the name put a bare "logs" / "exec" in a column of "working…",
  # which reads as a stray label rather than a status. It also hard-coded ONE
  # harness's vocabulary into the UI: the in-container harness calls a shell act
  # `Bash`, the in-process one `mcp__loopyard-container__exec` — the same act
  # would read differently per backend. Classify by neutral KIND and render a
  # calm verb (the harness-agnostic rule — see `Loopyard.Agent.ToolKind`).
  defp working_text(agent) do
    case Map.get(agent, :active_tool) do
      tool when is_binary(tool) and tool != "" ->
        tool |> ToolKind.classify() |> working_verb()

      _ ->
        "working…"
    end
  end

  defp working_verb(:command), do: "running…"
  defp working_verb(:read), do: "reading…"
  defp working_verb(:grep), do: "searching…"
  defp working_verb(:edit), do: "editing…"
  defp working_verb(:write), do: "writing…"
  defp working_verb(_), do: "working…"
end
