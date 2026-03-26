defmodule BoomLooperWeb.SystemController do
  use BoomLooperWeb, :controller

  @doc "GET /system/log — recent log entries as JSON. ?n=100&grep=pattern"
  def log(conn, params) do
    n = String.to_integer(params["n"] || "100")

    entries = case params["grep"] do
      nil -> BoomLooper.LogBuffer.recent(n)
      pattern -> BoomLooper.LogBuffer.grep(pattern, n)
    end

    json = Enum.map(entries, fn e ->
      %{
        level: e.level,
        message: e.message,
        module: if(e.module, do: inspect(e.module), else: nil)
      }
    end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(json, pretty: true))
  end
end
