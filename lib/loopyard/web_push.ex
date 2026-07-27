defmodule Loopyard.WebPush do
  @moduledoc """
  Web Push for the installed PWA — the "a question was asked, tell my phone"
  channel. Pure server-side: VAPID keys are generated once and persisted at
  `~/.loopyard/web_push.json` alongside the browser subscriptions; nothing to
  configure. `Questions.ask` calls `notify_question/4` so every pending
  question can reach a pocket; tapping the notification opens the Reviewer
  slide for that exact card (`/review/:agent_id/:msg_id`).

  Send path is `ExNudge` (RFC 8291/8292 — aes128gcm, which Apple requires).
  Expired subscriptions (endpoint gone, 404/410) are pruned on send.
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
        %{public_key: public, private_key: private} = ExNudge.VAPID.generate_vapid_keys()
        state = Map.merge(state, %{"public_key" => public, "private_key" => private})
        write(state)
        state
      end

    Application.put_env(:ex_nudge, :vapid_subject, "mailto:brad@rocketship.io")
    Application.put_env(:ex_nudge, :vapid_public_key, state["public_key"])
    Application.put_env(:ex_nudge, :vapid_private_key, state["private_key"])
    :ok
  rescue
    e ->
      Logger.warning("[WebPush] key setup failed: #{Exception.message(e)}")
      :ok
  end

  @doc "The VAPID public key the browser subscribes with."
  def public_key, do: load()["public_key"]

  @doc "Store a browser push subscription (unique by endpoint)."
  def subscribe(%{"endpoint" => endpoint} = sub) when is_binary(endpoint) do
    locked(fn ->
      state = load()
      subs = state["subscriptions"] || []
      subs = [sub | Enum.reject(subs, &(&1["endpoint"] == endpoint))]
      write(Map.put(state, "subscriptions", subs))
    end)
  end

  def subscribe(_), do: {:error, :invalid_subscription}

  def unsubscribe(endpoint) when is_binary(endpoint) do
    locked(fn ->
      state = load()
      subs = Enum.reject(state["subscriptions"] || [], &(&1["endpoint"] == endpoint))
      write(Map.put(state, "subscriptions", subs))
    end)
  end

  def subscriptions, do: load()["subscriptions"] || []

  @doc """
  Push a question to every subscribed device. Fire-and-forget (supervised
  task) — asking a question must NEVER block on push delivery.
  """
  def notify_question(title, body, url) do
    subs = subscriptions()

    if subs != [] do
      payload =
        Jason.encode!(%{
          title: title,
          body: String.slice(body || "", 0, 160),
          url: url,
          tag: url
        })

      Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
        Enum.each(subs, fn sub ->
          struct = %ExNudge.Subscription{
            endpoint: sub["endpoint"],
            keys: %{
              p256dh: get_in(sub, ["keys", "p256dh"]),
              auth: get_in(sub, ["keys", "auth"])
            }
          }

          case ExNudge.send_notification(struct, payload, urgency: :high, ttl: 3600) do
            {:ok, _} ->
              :ok

            {:error, :subscription_expired} ->
              # Device is gone — prune so we stop paying for it.
              unsubscribe(sub["endpoint"])

            {:error, reason} ->
              Logger.warning("[WebPush] send failed: #{inspect(reason)}")
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
