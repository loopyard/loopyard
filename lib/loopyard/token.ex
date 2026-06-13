defmodule Loopyard.Token do
  @moduledoc """
  The per-install **Loopyard token** + its **grants**.

  One minted secret authenticates internal requests *into* Loopyard from places
  that aren't a browser session — containers calling back to the host, future
  remote/internal endpoints. The secret is opaque; what it's *allowed to do*
  lives here, **server-side** — a set of grants. A caller presents the token; the
  server decides the capability. The client can't forge a grant: it isn't in the
  token, it's looked up.

  Today there's one grant — `open_url` (the browser-open bridge) — and one
  install token that holds it. The shape is built for more: per-token grant sets,
  `deploy` / `read_secrets` / etc. as the surface grows.

  Stored server-side at `<LOOPYARD_HOME>/token.json` (mode 0600), reused across
  restarts. Handed to containers via the `LOOPYARD_TOKEN` env var, presented in
  the `X-Loopyard-Token` header, checked with a constant-time compare. NOT the
  Erlang distribution cookie (that's the cluster secret — never hand it out).

  Grants are stored/compared as strings (JSON-friendly); the API accepts atoms
  or strings.
  """
  alias Loopyard.Workspace

  @header "x-loopyard-token"
  @env "LOOPYARD_TOKEN"
  # Grants a freshly-minted install token holds.
  @default_grants ["open_url"]

  @doc "The HTTP header internal callers present the token in."
  def header, do: @header

  @doc "The env var name containers read the token from."
  def env_var, do: @env

  @doc "The install secret (the opaque token string handed to containers)."
  @spec secret() :: String.t()
  def secret, do: load().secret

  @doc "The grants the install token currently holds (list of strings)."
  @spec grants() :: [String.t()]
  def grants, do: load().grants

  @doc "Constant-time check that `supplied` is the install token."
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(supplied) when is_binary(supplied),
    do: Plug.Crypto.secure_compare(supplied, secret())

  def valid?(_), do: false

  @doc "Is `supplied` the install token AND does it hold `grant`?"
  @spec has_grant?(String.t() | nil, atom() | String.t()) :: boolean()
  def has_grant?(supplied, grant),
    do: valid?(supplied) and to_string(grant) in grants()

  @doc "Add a grant to the install token (server-side). Persists. Idempotent."
  @spec grant(atom() | String.t()) :: :ok
  def grant(g), do: update_grants(&Enum.uniq([to_string(g) | &1]))

  @doc "Remove a grant from the install token (server-side). Persists."
  @spec revoke(atom() | String.t()) :: :ok
  def revoke(g), do: update_grants(&(&1 -- [to_string(g)]))

  # --- internals ---

  defp update_grants(fun) do
    state = load()
    persist(%{state | grants: fun.(state.grants)})
    :ok
  end

  # Read-or-mint the token record from disk. Mints a fresh secret + the default
  # grants on first use (or if the file is unreadable/corrupt).
  defp load do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"secret" => s, "grants" => g}} when is_binary(s) and is_list(g) <-
           Jason.decode(body) do
      %{secret: s, grants: g}
    else
      _ -> mint()
    end
  end

  defp mint do
    record = %{
      secret: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
      grants: @default_grants
    }

    persist(record)
  end

  defp persist(%{secret: s, grants: g} = record) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(%{"secret" => s, "grants" => g}))
    _ = File.chmod(path(), 0o600)
    record
  end

  defp path, do: Path.join(Workspace.home_dir(), "token.json")
end
