defmodule Loopyard.PushToken do
  @moduledoc """
  The secret that gates pushing env vars INTO Loopyard from outside (your dev
  Mac → the `PUT /env/:key` endpoint). One per-install bearer token at
  `<LOOPYARD_HOME>/push_token` (mode 0600), reused across restarts.

  This is deliberately narrow: it only authorizes the operator's own machine
  setting secrets on their own server (`gh auth token | curl … -H "Authorization:
  Bearer <token>"`). The endpoint is reachable over the public tunnel, so it's
  gated; the worst a tokenless request can do is nothing (403). The token is
  shown in the Workstation UI so you can copy the ready-made curl.
  """
  alias Loopyard.Workspace

  @doc "The install push secret, read-or-created at `<LOOPYARD_HOME>/push_token`."
  @spec get() :: String.t()
  def get do
    path = path()

    case File.read(path) do
      {:ok, t} when byte_size(t) >= 16 ->
        String.trim(t)

      _ ->
        t = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, t)
        _ = File.chmod(path, 0o600)
        t
    end
  end

  @doc "Constant-time check of a supplied bearer token."
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(supplied) when is_binary(supplied), do: Plug.Crypto.secure_compare(supplied, get())
  def valid?(_), do: false

  defp path, do: Path.join(Workspace.home_dir(), "push_token")
end
