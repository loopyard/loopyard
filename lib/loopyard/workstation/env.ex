defmodule Loopyard.Workstation.Env do
  @moduledoc """
  Env vars stamped into the workstation console **and** every agent container.

  This is the "pop a token into my workstation" layer: you set `KEY=value` here
  (a long-lived `CLAUDE_CODE_OAUTH_TOKEN`, a `GH_TOKEN`, an API key…), Loopyard
  persists it server-side and injects it as a plain `-e KEY=value` at
  `docker run`. The container just sees a normal env var — it never knows
  Loopyard's store exists. Management is centralized; delivery stays Unix-plain.

  Stored at `<LOOPYARD_HOME>/workstation/env.json` (mode 0600). Changes apply on
  the next container (re)create — i.e. hit **Restart** on the Workstation page.

  Single-user MVP: one global set shared by the console + all agents. Per-user /
  per-workspace scoping is a later refinement (the `Loopyard.Secrets` store
  already models scope if we want to merge them).
  """
  alias Loopyard.Workspace

  @key_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  # Known integrations — rendered as labeled paste slots so setup is "pick the
  # tool, paste the token" instead of "remember the variable name." Still just
  # env vars under the hood. `hint` says exactly how to mint the token.
  # An integration is a set of "ways to get the token", any/all of which render:
  #   * paste     — always; the value input (write-only).
  #   * cli/cli_label — a one-click "Import" that runs `cli` in the container to
  #     read/mint the token from an existing login (e.g. `gh auth token`). nil =
  #     no in-container path (Claude's setup-token needs a desktop browser).
  #   * commands  — runnable-doc steps: `%{cmd, label}` rendered as ▶ Run buttons
  #     that type the command into the console and take you to it. The terminal
  #     lives where we tell you to run things, instead of "go run this elsewhere."
  #   * setup     — :anywhere | :desktop (minting needs a same-machine browser).
  # (OAuth-redirect methods can slot in here later for services that support it.)
  @integrations [
    %{
      key: "GITHUB_TOKEN",
      label: "GitHub",
      hint: "Log in once (device flow — phone-friendly), then import the token.",
      setup: :anywhere,
      commands: [%{cmd: "gh auth login", label: "Run gh auth login"}],
      cli: "gh auth token",
      cli_label: "Import from gh"
    },
    %{
      key: "CLAUDE_CODE_OAUTH_TOKEN",
      label: "Claude",
      hint: "claude setup-token  on your Mac — Claude's loopback auth is hostile to remote",
      setup: :desktop,
      commands: [],
      cli: nil,
      cli_label: nil
    },
    %{
      key: "FLY_ACCESS_TOKEN",
      label: "Fly",
      hint: "fly tokens create",
      setup: :anywhere,
      commands: [],
      cli: nil,
      cli_label: nil
    }
  ]

  @doc "The known integrations rendered as guided slots (label, env key, how-to hint)."
  def integrations, do: @integrations

  @doc "Is `key` currently set?"
  @spec set?(String.t()) :: boolean()
  def set?(key), do: Map.has_key?(all(), key)

  @doc "The full env map, `%{\"KEY\" => \"value\"}`."
  @spec all() :: %{optional(String.t()) => String.t()}
  def all do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc "Sorted list of the env var names (no values)."
  @spec keys() :: [String.t()]
  def keys, do: all() |> Map.keys() |> Enum.sort()

  @doc "Set `key=value`. Validates the name is a legal env var. Overwrites."
  @spec put(String.t(), String.t()) :: :ok | {:error, :invalid_key}
  def put(key, value) when is_binary(key) and is_binary(value) do
    key = String.trim(key)

    if Regex.match?(@key_re, key) do
      all() |> Map.put(key, value) |> save()
      :ok
    else
      {:error, :invalid_key}
    end
  end

  @doc "Remove an env var."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    all() |> Map.delete(key) |> save()
    :ok
  end

  @doc "`docker run` args injecting every env var: `[\"-e\", \"K=V\", ...]`."
  @spec env_args() :: [String.t()]
  def env_args do
    all() |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  defp save(map) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(map))
    _ = File.chmod(path(), 0o600)
    :ok
  end

  defp path, do: Path.join([Workspace.home_dir(), "workstation", "env.json"])
end
