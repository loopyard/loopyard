defmodule LoopyardWeb.FileController do
  @moduledoc """
  Receive endpoint for pushing a credential FILE into the workstation `$HOME`
  volume from your Mac — for tools whose login lives in a file rather than an
  env var (Codex `~/.codex/auth.json`, gh `~/.config/gh/hosts.yml`, AWS, …):

      curl -T - http://localhost:4000/workstations/brad/file/.codex/auth.json < ~/.codex/auth.json

  The file lands in the shared `$HOME` volume, so every agent inherits it **live**
  (no Restart — unlike env vars). Same auth as the env push (local = no token,
  tunnel = `PushToken`); the path is validated to stay under `$HOME`.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Workstation
  alias Loopyard.Workstation.Container
  alias LoopyardWeb.PushAuth

  def put(conn, %{"id" => ws, "path" => segments}) do
    rel = Enum.join(List.wrap(segments), "/")

    cond do
      not PushAuth.authorized?(conn) ->
        conn |> put_status(:forbidden) |> json(%{error: "bad or missing push token"})

      not Workstation.exists?(ws) ->
        conn |> put_status(:not_found) |> json(%{error: "no such workstation: #{ws}"})

      true ->
        {:ok, body, conn} = read_body(conn, length: 5_000_000)

        case Container.write_file(rel, body, ws) do
          :ok -> send_resp(conn, :no_content, "")
          {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
        end
    end
  end
end
