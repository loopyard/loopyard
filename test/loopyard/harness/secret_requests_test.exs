defmodule Loopyard.Harness.SecretRequestsTest do
  use ExUnit.Case

  alias Loopyard.Harness.SecretRequests
  alias Loopyard.Secrets

  setup do
    # Isolate the on-disk secret store to a temp dir for the duration of the test.
    prev = System.get_env("LOOPYARD_HOME")
    tmp = Path.join(System.tmp_dir!(), "loopyard-secreq-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    System.put_env("LOOPYARD_HOME", tmp)

    # A fake agent so append_message_ets/update_message write straight to ETS.
    agent_id = "secreq-test-#{:rand.uniform(1_000_000)}"
    :ets.insert(:chat_agents, {agent_id, %{messages: []}})

    on_exit(fn ->
      if prev, do: System.put_env("LOOPYARD_HOME", prev), else: System.delete_env("LOOPYARD_HOME")
      File.rm_rf!(tmp)
      :ets.delete(:chat_agents, agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "submit stores the value to disk and unblocks with the KEY — the value never enters the transcript",
       %{agent_id: agent_id} do
    task = Task.async(fn -> SecretRequests.request(agent_id, "OPENAI_API_KEY", "to run tests") end)
    rid = wait_for_request(agent_id)

    # The submit returns the key, not the value.
    assert {:ok, "openai_api_key"} = SecretRequests.submit(rid, "sk-super-secret", "ws-1", "brad")
    # The blocked tool resumes with the key.
    assert {:ok, "openai_api_key"} = Task.await(task)

    # The value is on disk, scoped to the submitting workspace.
    assert {:ok, "sk-super-secret"} = Secrets.get("openai_api_key", "ws-1", nil)
    # …and scoped — invisible to another workspace.
    assert :not_found = Secrets.get("openai_api_key", "other-ws", nil)

    # The value is in NO chat message — only name/key/status/submitter.
    [{^agent_id, %{messages: msgs}}] = :ets.lookup(:chat_agents, agent_id)
    refute Enum.any?(msgs, fn m -> inspect(m) =~ "sk-super-secret" end)

    card = Enum.find(msgs, &(&1[:role] == :secret_request))
    assert card.status == :submitted
    assert card.submitted_by == "brad"
    assert card.name == "OPENAI_API_KEY"
    refute Map.has_key?(card, :value)
  end

  test "a submitted secret is stored + shown 'Submitted' to everyone even if the waiter died",
       %{agent_id: agent_id} do
    task = Task.async(fn -> SecretRequests.request(agent_id, "TOKEN", nil) end)
    rid = wait_for_request(agent_id)

    Task.shutdown(task, :brutal_kill)
    Process.sleep(20)

    # The requesting tool is gone, but the value must NOT be discarded: it's stored
    # and the card flips to :submitted for every viewer.
    assert {:ok, "token"} = SecretRequests.submit(rid, "tok-123", "ws-1", "brad")
    refute SecretRequests.pending?(rid)
    assert {:ok, "tok-123"} = Secrets.get("token", "ws-1", nil)

    [{^agent_id, %{messages: msgs}}] = :ets.lookup(:chat_agents, agent_id)
    card = Enum.find(msgs, &(&1[:role] == :secret_request))
    assert card.status == :submitted
  end

  test "cancel declines the request, flips the card to :declined, and resumes the agent",
       %{agent_id: agent_id} do
    task = Task.async(fn -> SecretRequests.request(agent_id, "GMAIL_TOKEN", "for tests") end)
    rid = wait_for_request(agent_id)

    assert :ok = SecretRequests.cancel(rid, nil)
    assert {:cancelled} = Task.await(task)
    refute SecretRequests.pending?(rid)

    [{^agent_id, %{messages: msgs}}] = :ets.lookup(:chat_agents, agent_id)
    card = Enum.find(msgs, &(&1[:role] == :secret_request))
    assert card.status == :declined

    # Nothing was stored.
    assert :not_found = Secrets.get("gmail_token", "ws-1", nil)
  end

  defp wait_for_request(agent_id, tries \\ 200) do
    case Enum.find(:ets.tab2list(:secret_requests), fn {_rid, e} -> e.agent_id == agent_id end) do
      {rid, _} ->
        rid

      nil when tries > 0 ->
        Process.sleep(5)
        wait_for_request(agent_id, tries - 1)

      nil ->
        flunk("secret request never registered")
    end
  end
end
