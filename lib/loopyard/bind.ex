defmodule Loopyard.Bind do
  @moduledoc """
  Where the web endpoint listens — a BOOT-TIME decision, not runtime state.

  Set `LOOPYARD_BIND` before starting the server:

      LOOPYARD_BIND=0.0.0.0   # reachable on the LAN
      LOOPYARD_BIND=127.0.0.1 # loopback only (the default)

  ## Why this replaced a UI toggle

  Exposure used to be a switch in the web UI (`/remote`, `Loopyard.HostExposer`)
  that rewrote the endpoint's `:ip` and restarted it, persisting the choice to
  `~/.loopyard/host_exposure.json`. Two things made that a bad idea:

    * **It could strand you.** The switch was reachable over the very
      connection it controlled. Hit "private" from your phone while
      traveling and the endpoint rebinds to loopback, severing the only
      link you had — and the page you'd use to undo it is now unreachable.
      Recovery meant physical access to the machine. Persistence made the
      lockout survive reboots.
    * **It was invisible state.** Losing that JSON file (a wipe, a fresh
      home, a new machine) silently un-exposed the server with no signal
      anywhere, which reads as "the server is broken."

  A boot flag has neither problem: it's declared where the process starts,
  it can't be flipped by a stray tap, and it's re-declared on every boot so
  there's no hidden file to lose. The UI still SHOWS the binding (System
  card) — it just can't change it.
  """

  @doc """
  The IP tuple to bind, parsed from `LOOPYARD_BIND`. Defaults to loopback.

  Parsing is STRICT on purpose. `:inet.parse_address/1` expands shorthand —
  it happily reads "0.0.0" as {0,0,0,0} — so a typo would silently expose the
  machine to the network. `parse_strict_address/1` rejects that, and anything
  unparseable falls back to loopback: a garbled value must never fail OPEN.
  """
  @spec configured_ip() :: :inet.ip_address()
  def configured_ip do
    case System.get_env("LOOPYARD_BIND") do
      nil -> {127, 0, 0, 1}
      "" -> {127, 0, 0, 1}
      val -> parse(val)
    end
  end

  defp parse(val) do
    val = String.trim(val)

    case :inet.parse_strict_address(String.to_charlist(val)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  @doc """
  Is the endpoint reachable beyond localhost?

  Reads the endpoint's ACTUAL configured ip, so it reports what the running
  server is doing rather than re-reading the env var.
  """
  @spec exposed?() :: boolean()
  def exposed? do
    case endpoint_ip() do
      {127, 0, 0, 1} -> false
      nil -> false
      _ -> true
    end
  end

  @doc "The endpoint's bound address as a string, e.g. `0.0.0.0:4000`."
  @spec describe() :: String.t()
  def describe do
    ip = endpoint_ip()
    port = endpoint_port()

    case ip do
      nil -> "unknown"
      tuple -> "#{tuple |> :inet.ntoa() |> to_string()}:#{port}"
    end
  end

  defp endpoint_ip do
    :loopyard
    |> Application.get_env(LoopyardWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:ip)
  end

  defp endpoint_port do
    :loopyard
    |> Application.get_env(LoopyardWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4000)
  end
end
