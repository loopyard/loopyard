defmodule Loopyard.Harness.Catalog do
  @moduledoc """
  The ONE place that knows which agent harnesses exist and how to launch them.

  Every harness Loopyard supports speaks ACP, so they all share
  `Loopyard.Harness.ACP` — the connection, translator, resume, MCP bridge,
  questions and approvals are vendor-neutral. What differs per vendor is only:

    * which adapter binary runs inside the work container,
    * which process name the orphan sweep looks for,
    * which credential unlocks it.

  That's the whole seam. Adding a harness is an entry here plus its adapter in
  `priv/workspace-base/Dockerfile` — no changes to the connection, the
  translator, the UI, or the tool layer.

  Do NOT branch on harness id anywhere else. The UI renders tools by
  `Loopyard.Agent.ToolKind`, not by vendor; if a per-vendor difference shows up
  that isn't launch or credentials, it belongs in this struct as a field, not in
  a `case` at the call site.
  """

  @type id :: :claude | :codex

  @type t :: %{
          id: id(),
          label: String.t(),
          adapter: String.t(),
          proc_match: String.t(),
          credential_keys: [String.t()],
          env: %{String.t() => String.t()},
          models: [{String.t(), String.t()}]
        }

  # Order is display order in the harness picker.
  @harnesses [
    %{
      id: :claude,
      label: "Claude Code",
      adapter: "claude-agent-acp",
      # The orphan sweep greps container cmdlines for this: both the adapter
      # (node …claude-agent-acp) and the `claude` child it spawns match.
      proc_match: "claude",
      # Either unlocks the harness. The OAuth token is what
      # `Workstation.Env` provisions; an API key is the BYO-key path.
      credential_keys: ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
      env: %{},
      # Offered in the picker. The in-container CLI's set_model passes FULL
      # model ids through (verified), so these are ids rather than the adapter's
      # stale default/opus/haiku aliases.
      models: [
        {"claude-opus-4-8", "Opus 4.8"},
        {"claude-fable-5", "Fable 5"},
        {"claude-sonnet-5", "Sonnet 5"},
        {"claude-haiku-4-5-20251001", "Haiku 4.5"}
      ]
    },
    %{
      id: :codex,
      label: "Codex",
      adapter: "codex-acp",
      proc_match: "codex",
      # CODEX_API_KEY wins over OPENAI_API_KEY in the adapter itself; listing
      # both means either one lights the harness up in the picker.
      credential_keys: ["CODEX_API_KEY", "OPENAI_API_KEY"],
      # Our containers are headless: without this the adapter advertises the
      # browser-based ChatGPT login as an auth method and a session can hang
      # waiting on a login nobody can complete.
      env: %{"NO_BROWSER" => "1"},
      # Deliberately empty: Codex model ids move faster than this file, and a
      # stale id here is not a cosmetic bug — set_model REJECTS an unknown id, so
      # the agent would fail to start on a model the picker offered. Selecting
      # Codex runs the adapter's own current default; the live model list from
      # the session is the right long-term source (see plans/multi-agent-harnesses.md).
      models: []
    }
  ]

  @default :claude

  @doc "Every known harness, in display order."
  @spec all() :: [t()]
  def all, do: @harnesses

  @doc "The harness used when none is specified."
  @spec default() :: id()
  def default, do: @default

  @doc """
  Look up a harness by id. Accepts the atom or its string form so a value
  round-tripped through JSON/params doesn't need converting at the call site.
  Unknown ids fall back to the default rather than raising — a persisted agent
  naming a harness we've since removed must still boot.
  """
  @spec fetch(id() | String.t() | nil) :: t()
  def fetch(nil), do: fetch(@default)

  def fetch(id) when is_binary(id) do
    case Enum.find(@harnesses, &(Atom.to_string(&1.id) == id)) do
      nil -> fetch(@default)
      harness -> harness
    end
  end

  def fetch(id) when is_atom(id) do
    Enum.find(@harnesses, &(&1.id == id)) || Enum.find(@harnesses, &(&1.id == @default))
  end

  @doc "Adapter binary for a harness — what `docker exec` runs in the work container."
  @spec adapter(id() | String.t() | nil) :: String.t()
  def adapter(id), do: fetch(id).adapter

  @doc "Human label, e.g. for the picker."
  @spec label(id() | String.t() | nil) :: String.t()
  def label(id), do: fetch(id).label

  @doc """
  Whether a harness has a usable credential in `env` (any of its keys set to a
  non-empty value).

  ADVISORY ONLY — never gate the picker on this. `false` does not mean the
  harness won't work: Codex also authenticates from `~/.codex/auth.json` written
  by `codex login`, which lives in the container's $HOME volume and can only be
  confirmed with a round-trip (`Workstation.Integration.connected?/2`) far too
  slow to render a menu with. Disabling on a false negative would hide a harness
  that works perfectly; a hint next to an enabled option costs nothing when
  it's wrong.
  """
  @spec credentialed?(id() | String.t() | nil, %{optional(String.t()) => String.t()}) :: boolean()
  def credentialed?(id, env) when is_map(env) do
    Enum.any?(fetch(id).credential_keys, fn key ->
      case Map.get(env, key) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  @doc "Credential keys that would unlock this harness, for the 'how to fix' line."
  @spec credential_keys(id() | String.t() | nil) :: [String.t()]
  def credential_keys(id), do: fetch(id).credential_keys

  @doc """
  Model options for the picker: `{value, label}` pairs where `value` is the
  `harness:model` token `parse_selection/1` reads back.

  Every harness gets an "adapter default" entry — for one with no pinned model
  list that IS the whole menu, and it's what makes a harness selectable before
  we know its model vocabulary.
  """
  @spec model_options(id() | String.t() | nil) :: [{String.t(), String.t()}]
  def model_options(id) do
    harness = fetch(id)
    key = Atom.to_string(harness.id)

    Enum.map(harness.models, fn {model, label} -> {"#{key}:#{model}", label} end) ++
      [{"#{key}:default", "Adapter default"}]
  end

  @doc """
  Read a picker selection back into `{harness_id, model}`, where `model` is nil
  for the adapter default.

  Returns `:error` for anything unparseable rather than guessing — a malformed
  selection must not silently switch the agent to the default harness.
  """
  @spec parse_selection(String.t()) :: {:ok, id(), String.t() | nil} | :error
  def parse_selection(value) when is_binary(value) do
    with [harness, model] <- String.split(value, ":", parts: 2),
         true <- Enum.any?(@harnesses, &(Atom.to_string(&1.id) == harness)) do
      {:ok, fetch(harness).id, if(model == "default", do: nil, else: model)}
    else
      _ -> :error
    end
  end

  def parse_selection(_), do: :error
end
