defmodule Loopyard.WebPush do
  @moduledoc """
  Web Push for the installed PWA — the "a question was asked, tell my phone"
  channel. Pure server-side: VAPID keys are generated once and persisted at
  `~/.loopyard/web_push.json` alongside the browser subscriptions (each with
  the KINDS it wants); nothing to configure. `Loopyard.Notifications.Push`
  calls `notify/4` for every item raised on the inbox, so every decision —
  and, opt-in per device, every finished turn — can reach a pocket; tapping
  the notification opens that item's slide (`/notifications/:agent/:msg`).

  `WebPushEx` builds the signed RFC 8291/8292 (aes128gcm — what Apple
  requires) request; delivery is plain `:httpc` with verified TLS, so no
  extra HTTP-client dependency. Expired subscriptions (404/410) prune on
  send.
  """

  require Logger

  def path, do: Path.join(Loopyard.Workspace.home_dir(), "web_push.json")

  @doc """
  Load-or-mint the VAPID keypair and hand it to :ex_nudge's app config.
  Called at boot; idempotent.
  """
  def ensure_keys do
    state = load()

    state =
      if is_binary(state["public_key"]) and is_binary(state["private_key"]) do
        state
      else
        {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

        state =
          Map.merge(state, %{
            "public_key" => Base.url_encode64(public, padding: false),
            "private_key" => Base.url_encode64(private, padding: false)
          })

        write(state)
        state
      end

    Application.put_env(:web_push_ex, :vapid,
      subject: "mailto:brad@rocketship.io",
      public_key: state["public_key"],
      private_key: state["private_key"]
    )

    :ok
  rescue
    e ->
      Logger.warning("[WebPush] key setup failed: #{Exception.message(e)}")
      :ok
  end

  @doc "The VAPID public key the browser subscribes with."
  def public_key, do: load()["public_key"]

  @doc """
  Store a browser push subscription (unique by endpoint) with the KINDS it
  wants: `"decision"` always; `"finished"` (agents wrapping a turn) is opt-in.
  """
  def subscribe(sub, kinds \\ ["decision"])

  def subscribe(%{"endpoint" => endpoint} = sub, kinds) when is_binary(endpoint) do
    sub = Map.put(sub, "kinds", normalize_kinds(kinds))

    locked(fn ->
      state = load()
      subs = state["subscriptions"] || []
      subs = [sub | Enum.reject(subs, &(&1["endpoint"] == endpoint))]
      write(Map.put(state, "subscriptions", subs))
    end)
  end

  def subscribe(_, _), do: {:error, :invalid_subscription}

  @doc "Change which kinds one device wants."
  def set_kinds(endpoint, kinds) when is_binary(endpoint) do
    locked(fn ->
      state = load()

      subs =
        Enum.map(state["subscriptions"] || [], fn s ->
          if s["endpoint"] == endpoint, do: Map.put(s, "kinds", normalize_kinds(kinds)), else: s
        end)

      write(Map.put(state, "subscriptions", subs))
    end)
  end

  @doc "Does this subscription want pushes of `kind` (`:decision | :finished`)?"
  def wants?(sub, :decision), do: "decision" in kinds_of(sub)
  def wants?(sub, :finished), do: "finished" in kinds_of(sub)
  def wants?(_sub, _), do: false

  defp kinds_of(sub), do: sub["kinds"] || ["decision"]

  defp normalize_kinds(kinds) when is_list(kinds),
    do: ["decision" | Enum.map(kinds, &to_string/1)] |> Enum.uniq()

  defp normalize_kinds(_), do: ["decision"]

  def unsubscribe(endpoint) when is_binary(endpoint) do
    locked(fn ->
      state = load()
      subs = Enum.reject(state["subscriptions"] || [], &(&1["endpoint"] == endpoint))
      write(Map.put(state, "subscriptions", subs))
    end)
  end

  def subscriptions, do: load()["subscriptions"] || []

  @doc """
  Push an inbox item of `kind` (`:decision | :finished`) to every device that
  wants that kind. Fire-and-forget (supervised task) — raising an item must
  NEVER block on push delivery. Fired by `Loopyard.Notifications.Push`.
  """
  def notify(kind, title, body, url) when kind in [:decision, :finished] do
    subs = Enum.filter(subscriptions(), &wants?(&1, kind))

    if subs != [] do
      payload =
        Jason.encode!(%{
          title: title,
          body: String.slice(body || "", 0, 160),
          url: url,
          tag: url,
          # Stamped on the app icon by the service worker — the only context
          # that can badge a CLOSED app (iOS included).
          badge: waiting_count()
        })

      Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
        Enum.each(subs, fn sub ->
          struct = %WebPushEx.Subscription{
            endpoint: URI.parse(sub["endpoint"]),
            keys: %{
              p256dh: get_in(sub, ["keys", "p256dh"]),
              auth: get_in(sub, ["keys", "auth"])
            }
          }

          req = WebPushEx.request(struct, payload)
          headers = Map.merge(req.headers, %{"Urgency" => "high", "TTL" => "3600"})

          case deliver(URI.to_string(req.endpoint), headers, req.body) do
            {:ok, status} when status in 200..299 ->
              :ok

            {:ok, status} when status in [404, 410] ->
              # Device is gone — prune so we stop paying for it.
              unsubscribe(sub["endpoint"])

            other ->
              Logger.warning("[WebPush] send failed: #{inspect(other)}")
          end
        end)
      end)
    end

    :ok
  rescue
    e ->
      Logger.warning("[WebPush] notify failed: #{Exception.message(e)}")
      :ok
  end

  @doc "A decision push (kept for callers; new ones go through the inbox)."
  def notify_question(title, body, url), do: notify(:decision, title, body, url)

  @doc """
  Push to ONE just-subscribed device — the instant "it works" confirmation
  (also stamps the current badge, so the count appears without waiting for
  the next question).
  """
  def notify_one(sub, title, body, url) do
    payload =
      Jason.encode!(%{title: title, body: body, url: url, badge: waiting_count()})

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      struct = %WebPushEx.Subscription{
        endpoint: URI.parse(sub["endpoint"]),
        keys: %{p256dh: get_in(sub, ["keys", "p256dh"]), auth: get_in(sub, ["keys", "auth"])}
      }

      req = WebPushEx.request(struct, payload)

      case deliver(URI.to_string(req.endpoint), req.headers, req.body) do
        {:ok, status} when status in 200..299 -> :ok
        other -> Logger.warning("[WebPush] welcome push failed: #{inspect(other)}")
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning("[WebPush] notify_one failed: #{Exception.message(e)}")
      :ok
  end

  # Everything open on the inbox — decisions AND finished turns — since a
  # tap on the badge lands on the inbox, not the decisions alone.
  defp waiting_count do
    Loopyard.Notifications.count()
  rescue
    _ -> 1
  catch
    _, _ -> 1
  end

  # :httpc POST with verified TLS (OS trust store) — the endpoints are the
  # browser vendors' push services; no client dep needed for four headers.
  defp deliver(url, headers, body) do
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(url), hdrs, ~c"application/octet-stream", body},
           [ssl: ssl, timeout: 15_000],
           []
         ) do
      {:ok, {{_, status, _}, _hdrs, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── store (RMW under a lock, like Peering was) ─────────────────────────────

  defp locked(fun), do: :global.trans({{__MODULE__, :store}, self()}, fun)

  defp load do
    case File.read(path()) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write(state) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(state, pretty: true))
    :ok
  end
end
