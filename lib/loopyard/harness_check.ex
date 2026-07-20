defmodule Loopyard.HarnessCheck do
  @moduledoc """
  Self-validation that Loopyard can actually drive a frontier harness end to end.

  `probe/1` is the cheap one: it spawns a real `Loopyard.Harness.*` session
  (Claude Code by default), streams ONE probe prompt, and confirms the expected
  token comes back through the neutral `Loopyard.Agent.Event` stream. That
  exercises the whole harness path — CLI present + authed, the adapter, the
  Event translation, the stream lifecycle — without needing a workspace,
  container, or ChatAgent.

  `agent_turn/2` is the full path: it drives a live `ChatAgent` (the durable
  inbox + turn execution) and confirms the response lands in the message log.

  Run from a loop to catch harness regressions:

      mix loopyard.harness_check          # probe the default harness
      mix loopyard.harness_check --full <agent_id>

  or directly on the node:

      mix loopyard.rpc "Loopyard.HarnessCheck.probe() |> IO.inspect()"
  """

  alias Loopyard.Agent.Event

  @default_timeout_ms 60_000

  @doc """
  Round-trip a single prompt through a harness session. Returns
  `{:ok, %{latency_ms, response, backend}}` or `{:error, detail}`.
  """
  @spec probe(keyword()) :: {:ok, map()} | {:error, map()}
  def probe(opts \\ []) do
    backend = Keyword.get(opts, :backend, default_backend())
    token = "LOOPYARD-OK-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    session_opts = [
      cwd: System.tmp_dir!(),
      permission_mode: :accept_edits,
      dangerously_skip_permissions: true,
      append_system_prompt:
        "You are a connectivity probe. Reply with ONLY what the user asks, verbatim, nothing else.",
      allowed_tools: [],
      thinking: :disabled
    ]

    t0 = System.monotonic_time(:millisecond)

    case backend.start_session(session_opts) do
      {:ok, session} ->
        try do
          collect_text(backend, session, "Reply with exactly this token: #{token}")
          |> evaluate(token, backend, t0)
        catch
          kind, reason ->
            {:error, %{reason: :stream_crashed, detail: {kind, reason}, backend: backend}}
        after
          backend.stop(session)
        end

      {:error, reason} ->
        {:error, %{reason: :start_session_failed, detail: reason, backend: backend}}
    end
  end

  defp collect_text(backend, session, prompt) do
    backend.stream(session, prompt)
    |> Enum.reduce("", fn
      %Event.Text{text: t}, acc -> acc <> (t || "")
      _other, acc -> acc
    end)
  end

  defp evaluate(text, token, backend, t0) do
    latency = System.monotonic_time(:millisecond) - t0
    response = String.trim(text)

    if String.contains?(response, token) do
      {:ok, %{latency_ms: latency, response: response, backend: backend}}
    else
      {:error,
       %{
         reason: :token_not_found,
         expected: token,
         got: response,
         latency_ms: latency,
         backend: backend
       }}
    end
  end

  @doc """
  Full-path check: send a probe to a LIVE `ChatAgent` and confirm a fresh
  assistant message containing the token lands within the timeout.
  """
  @spec agent_turn(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def agent_turn(agent_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    token = "LOOPYARD-OK-" <> Integer.to_string(:erlang.unique_integer([:positive]))

    case Loopyard.ChatAgent.get_state(agent_id) do
      nil ->
        {:error, %{reason: :agent_not_found, agent_id: agent_id}}

      _ ->
        t0 = System.monotonic_time(:millisecond)
        Loopyard.ChatAgent.send_message(agent_id, "Reply with exactly this token: #{token}")
        await_token(agent_id, token, t0, t0 + timeout)
    end
  end

  defp await_token(agent_id, token, t0, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, %{reason: :timeout, agent_id: agent_id, token: token}}
    else
      {msgs, _} = Loopyard.ChatAgent.get_messages(agent_id, limit: 10)

      hit =
        Enum.find(msgs, fn m ->
          m.role == :assistant and is_binary(m[:content]) and String.contains?(m.content, token)
        end)

      if hit do
        {:ok,
         %{
           latency_ms: System.monotonic_time(:millisecond) - t0,
           response: String.trim(hit.content)
         }}
      else
        Process.sleep(500)
        await_token(agent_id, token, t0, deadline)
      end
    end
  end

  defp default_backend do
    Application.get_env(:loopyard, :default_harness, Loopyard.Harness.ACP)
  end
end
