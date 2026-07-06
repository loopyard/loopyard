defmodule LoopyardWeb.SetupController do
  @moduledoc """
  Serves the one-shot credential-transfer script for a *named* workstation. On
  your Mac:

      curl -fsS http://localhost:4000/workstations/brad/setup.sh | sh

  The script is just the per-tool transfer scripts (`Integration.mac_script/4`)
  concatenated, with the push-token header baked in. Those are **keychain-aware**:
  on macOS `gh` and Claude keep credentials in the Keychain, not files, and Claude
  also needs its onboarding config — a naive `cat ~/.claude/.credentials.json`
  transfers nothing. Host, push token, and target workstation are baked in from
  the request, so it Just Works against this Loopyard.

  Gated by `PushAuth` (local = no token; remote fetch needs `?token=`).
  """
  use LoopyardWeb, :controller

  alias Loopyard.{PushToken, Workstation}
  alias Loopyard.Workstation.Integration
  alias LoopyardWeb.PushAuth

  def script(conn, %{"id" => ws}) do
    cond do
      not PushAuth.authorized?(conn) ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(403, "echo 'Loopyard: unauthorized — append ?token=<push-token>'\n")

      not Workstation.exists?(ws) ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(404, "echo 'Loopyard: no such workstation: #{ws}'\n")

      true ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(200, build_script(base_url(conn), PushToken.get(), ws))
    end
  end

  @doc """
  Serves ONE tool's transfer script — so the per-tool page shows a clean
  `curl …/:tool/setup.sh | sh` instead of a giant pasted blob.

  Claude is special: its durable path (`claude setup-token`, a 1-year token) is
  interactive, so its script mints that token and pushes it — not the short-lived
  keychain copy the bulk transfer uses.
  """
  def tool_script(conn, %{"id" => ws, "tool" => tool}) do
    cond do
      not PushAuth.authorized?(conn) ->
        shell(conn, 403, "echo 'Loopyard: unauthorized — append ?token=<push-token>'\n")

      not Workstation.exists?(ws) ->
        shell(conn, 404, "echo 'Loopyard: no such workstation: #{ws}'\n")

      is_nil(Integration.get(tool)) ->
        shell(conn, 404, "echo 'Loopyard: no such tool: #{tool}'\n")

      true ->
        shell(
          conn,
          200,
          tool_script_body(Integration.get(tool), base_url(conn), PushToken.get(), ws)
        )
    end
  end

  defp shell(conn, status, body) do
    conn |> put_resp_content_type("text/x-shellscript") |> send_resp(status, body)
  end

  # Claude → mint a long-lived token (browser OAuth) and push it. The token is
  # extracted by pattern so prose around it doesn't matter; graceful fallback.
  defp tool_script_body(%{id: "claude"}, base, token, ws) do
    env_url = "#{base}/workstations/#{ws}/env/CLAUDE_CODE_OAUTH_TOKEN"

    """
    #!/bin/sh
    # Loopyard — mint a long-lived Claude token and push it into workstation '#{ws}'.
    command -v claude >/dev/null 2>&1 || { echo "Install Claude Code on your Mac first."; exit 1; }
    echo "Authorizing Claude — a browser will open; approve it to mint a 1-year token."
    t=$(claude setup-token 2>/dev/null | grep -oE 'sk-ant-oat[A-Za-z0-9_-]+' | head -1)
    if [ -n "$t" ]; then
      printf '%s' "$t" | curl -fsS -H "Authorization: Bearer #{token}" -T - "#{env_url}"
      echo
      echo "Pushed CLAUDE_CODE_OAUTH_TOKEN to '#{ws}'. Restart the box to apply."
    else
      echo "Couldn't capture a token. Run 'claude setup-token' yourself, then paste it on the Claude page."
    fi
    """
  end

  # Everything else → the tool's keychain/file transfer, wrapped as a runnable script.
  defp tool_script_body(ig, base, token, ws) do
    """
    #!/bin/sh
    # Loopyard — transfer your #{ig.label} login into workstation '#{ws}'.
    L="#{base}"
    WS="#{ws}"
    AUTH="Authorization: Bearer #{token}"
    echo "Transferring #{ig.label} → $L (workstation: $WS)"
    #{Integration.mac_script(ig, "$L", "$WS", ~s(-fsS -H "$AUTH"))}
    echo "Done. Files apply live; env tokens apply on the next Restart."
    """
  end

  defp base_url(conn) do
    proto = first(conn, "x-forwarded-proto", to_string(conn.scheme))
    host = first(conn, "host", "#{conn.host}:#{conn.port}")
    "#{proto}://#{host}"
  end

  defp first(conn, header, default) do
    case get_req_header(conn, header) do
      [v | _] -> v
      _ -> default
    end
  end

  defp build_script(base, token, ws) do
    # Each tool's transfer is `Integration.mac_script/4` with the push-token
    # header (so it works over the tunnel too). The scripts are self-guarding —
    # they push nothing if the credential isn't present.
    tools =
      Integration.all()
      |> Enum.map_join("\n\n", fn ig ->
        ~s(echo "  #{ig.label}…"\n) <>
          Integration.mac_script(ig, "$L", "$WS", ~s(-fsS -H "$AUTH"))
      end)

    """
    #!/bin/sh
    # Loopyard — transfer your logged-in Mac credentials into workstation '#{ws}'.
    # Run on the Mac where you're logged in:
    #   curl -fsS #{base}/workstations/#{ws}/setup.sh | sh
    # Keychain-aware: gh + Claude keep creds in the macOS Keychain, not files.
    L="#{base}"
    WS="#{ws}"
    AUTH="Authorization: Bearer #{token}"

    echo "Transferring your logins → $L (workstation: $WS)"

    #{tools}

    echo "Done. Files are live now; GitHub/Fly env tokens apply on the next Restart."
    """
  end
end
