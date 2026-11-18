defmodule Loopyard.Harness.Models do
  @moduledoc """
  The models a harness offers, as the harness itself reports them.

  Every ACP session lists its models (`Connection.available_models/1`). The
  newest list any session of a harness reported is kept here and is what the
  pickers offer, so a newer adapter in the work image brings its newer models
  with no edit to Loopyard. Until a session of that harness has started since
  boot, `list/1` answers with the Catalog entry's `models` seed.

  Claude's list is aliases (`opus`, `fable`, `sonnet`, `haiku`) that Claude
  Code resolves to the current release, each labelled with what it resolves to
  ("Opus 5.5"), followed by the pinned older releases the account can still
  reach. Only the aliases are kept when a harness has any (`current/1`), and
  `float/2` moves a stored pin from an older release (`claude-opus-5`, or its
  display name "Opus 5") onto the alias of its family.

  Held in `:persistent_term`: a handful of small lists, written only when a
  session reports one that differs, read on every sidebar render.
  """

  alias Loopyard.Harness.Catalog

  @type entry :: {id :: String.t(), label :: String.t()}

  @doc "The harness's models, `{id, label}` in the adapter's own order."
  @spec list(Catalog.id() | String.t() | nil) :: [entry()]
  def list(harness) do
    spec = Catalog.fetch(harness)

    case :persistent_term.get(key(spec.id), nil) do
      [_ | _] = live -> live
      _ -> spec.models
    end
  end

  @doc """
  Remember the list a live session reported (`[%{id:, label:}]`). The adapter's
  own `default` entry is left out: the pickers add "Adapter default" themselves.
  """
  @spec record(Catalog.id() | String.t() | nil, term()) :: :ok
  def record(harness, models) when is_list(models) do
    live =
      for %{id: id} = m <- models, is_binary(id), id not in ["", "default"] do
        {id, label(m) || id}
      end

    live = current(live)
    key = key(Catalog.fetch(harness).id)
    if live != [] and :persistent_term.get(key, nil) != live, do: :persistent_term.put(key, live)
    :ok
  end

  def record(_harness, _models), do: :ok

  @doc """
  Record what an agent's live session advertises, and name the agent's model
  the way that session does ("opus" → "Opus 5.5") so the sidebar is right
  before the first turn ends. Called where every new session lands
  (`SessionManager.track_os_pid/1`); returns the state, never raises.
  """
  @spec capture(map()) :: map()
  def capture(%{session: session, backend: backend} = state) when not is_nil(session) do
    opts = Map.get(state, :session_opts) || []
    harness = Keyword.get(opts, :harness)

    # Only a backend that lists models: for any other, `session_opts[:model]`
    # is not something this session was asked to run.
    if function_exported?(backend, :available_models, 1) do
      models = backend.available_models(session)
      record(harness, models)
      named = Enum.find(models, &(is_map(&1) and &1[:id] == Keyword.get(opts, :model)))

      case named && label(named) do
        label when is_binary(label) and is_map_key(state, :model) -> %{state | model: label}
        _ -> state
      end
    else
      state
    end
  rescue
    _ -> state
  catch
    _, _ -> state
  end

  def capture(state), do: state

  @doc "Whether `id` is a model this harness offers."
  @spec member?(Catalog.id() | String.t() | nil, term()) :: boolean()
  def member?(harness, id) when is_binary(id), do: List.keymember?(list(harness), id, 0)
  def member?(_harness, _id), do: false

  @doc """
  The id to run for a stored model value: the value itself when the harness
  offers it (by id or by label), else the alias of its family when the Catalog
  entry names a pattern for that (`model_alias`) and the harness offers the
  alias, else nil — the caller then starts on the harness default.
  """
  @spec float(Catalog.id() | String.t() | nil, term()) :: String.t() | nil
  def float(harness, model) when is_binary(model) do
    models = list(harness)

    case Enum.find(models, fn {id, label} -> model in [id, label] end) do
      {id, _label} ->
        id

      nil ->
        family = family(Catalog.fetch(harness), model)
        if family && List.keymember?(models, family, 0), do: family
    end
  end

  def float(_harness, _model), do: nil

  @doc "Forget every recorded list (tests)."
  @spec reset() :: :ok
  def reset do
    Enum.each(Catalog.all(), &:persistent_term.erase(key(&1.id)))
  end

  # A harness that offers floating aliases is offered BY alias. Claude Code
  # also lists the pinned releases an account can still reach ("claude-opus-5",
  # "claude-opus-4-8", nine of them in Nov 2026); offering those is how an agent
  # stays on last year's model. An alias has no version in its id, a pinned
  # release does — the same test `Connection.Models` uses. A harness with no
  # aliases (every id pinned) is offered whole.
  defp current(entries) do
    case Enum.reject(entries, fn {id, _label} -> id =~ ~r/\d/ end) do
      [] -> entries
      aliases -> aliases
    end
  end

  defp family(%{model_alias: pattern}, model) when is_binary(pattern) do
    case Regex.run(Regex.compile!(pattern), model) do
      [_, family] -> String.downcase(family)
      _ -> nil
    end
  end

  defp family(_spec, _model), do: nil

  defp label(%{label: l}) when is_binary(l) and l != "", do: l
  defp label(%{name: n}) when is_binary(n) and n != "", do: n
  defp label(_), do: nil

  defp key(id), do: {__MODULE__, id}
end
