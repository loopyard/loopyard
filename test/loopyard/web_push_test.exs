defmodule Loopyard.WebPushTest do
  use ExUnit.Case, async: false

  alias Loopyard.WebPush

  setup do
    # The store file is shared — save/restore around each test.
    saved = File.read(WebPush.path())

    on_exit(fn ->
      case saved do
        {:ok, raw} -> File.write!(WebPush.path(), raw)
        _ -> File.rm(WebPush.path())
      end
    end)

    :ok
  end

  test "ensure_keys mints once and is stable across calls" do
    File.rm(WebPush.path())
    assert :ok = WebPush.ensure_keys()
    key = WebPush.public_key()
    assert is_binary(key) and byte_size(key) > 20

    assert :ok = WebPush.ensure_keys()
    assert WebPush.public_key() == key
  end

  test "subscriptions round-trip, dedupe by endpoint, and unsubscribe" do
    sub = %{
      "endpoint" => "https://push.example/#{System.unique_integer([:positive])}",
      "keys" => %{"p256dh" => "pk", "auth" => "a"}
    }

    assert :ok = WebPush.subscribe(sub)
    assert :ok = WebPush.subscribe(sub)
    assert Enum.count(WebPush.subscriptions(), &(&1["endpoint"] == sub["endpoint"])) == 1

    WebPush.unsubscribe(sub["endpoint"])
    refute Enum.any?(WebPush.subscriptions(), &(&1["endpoint"] == sub["endpoint"]))
  end

  test "rejects a subscription without an endpoint" do
    assert {:error, :invalid_subscription} = WebPush.subscribe(%{"keys" => %{}})
  end

  test "notify_question with no subscriptions is a cheap no-op" do
    File.rm(WebPush.path())
    assert :ok = WebPush.notify_question("t", "b", "/notifications")
  end

  test "a device gets decisions by default and finished turns only when it asked" do
    sub = %{
      "endpoint" => "https://push.example/dev-#{System.unique_integer([:positive])}",
      "keys" => %{}
    }

    assert :ok = WebPush.subscribe(sub)
    stored = Enum.find(WebPush.subscriptions(), &(&1["endpoint"] == sub["endpoint"]))
    assert WebPush.wants?(stored, :decision)
    refute WebPush.wants?(stored, :finished)

    assert :ok = WebPush.set_kinds(sub["endpoint"], ["finished"])
    stored = Enum.find(WebPush.subscriptions(), &(&1["endpoint"] == sub["endpoint"]))
    assert WebPush.wants?(stored, :finished)
    assert WebPush.wants?(stored, :decision), "decisions are never opted out of"

    WebPush.unsubscribe(sub["endpoint"])
  end

  test "an inbox item's push names the kind and links its own slide" do
    alias Loopyard.Notifications.{Item, Push}

    fin = %Item{
      id: "fin:a1",
      kind: :finished,
      agent_id: "a1",
      project_name: "gbrain",
      workspace_name: "main"
    }

    assert Push.title(fin) == "Finished — gbrain · main"
    assert Push.url(fin) == "/notifications/a1/fin"

    q = %Item{id: "q9", kind: :question, agent_id: "a2", msg_id: "m9", agent_name: "Operator"}
    assert Push.title(q) == "Decision — Operator"
    assert Push.url(q) == "/notifications/a2/m9"
  end
end
