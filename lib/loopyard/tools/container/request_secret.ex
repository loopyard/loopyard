defmodule Loopyard.Tools.Container.RequestSecret do
  use Loopyard.Tool,
    name: "request_secret",
    description:
      "Ask the human for a secret (an API key, token, password) WITHOUT it going " <>
        "through the chat. Shows them a masked input field; when they submit, the " <>
        "value is written straight to Loopyard's encrypted-at-rest secret store " <>
        "(scoped to this workspace) and NEVER appears in the transcript. Blocks " <>
        "until they submit. You get back the storage KEY — read the value later " <>
        "with `get_secret` only when you actually need it (e.g. to set an env var " <>
        "before a command). Use this instead of asking the user to paste a secret " <>
        "into chat.",
    busy_words: ["waiting for a secret", "requesting a key"],
    params: [
      agent_id: {:string, required: true},
      name: {:string, required: true, description: "The secret's name, e.g. OPENAI_API_KEY."},
      why:
        {:string,
         required: false,
         description: "One short line on what it's for — shown to the human on the card."}
    ]

  alias Loopyard.Harness.SecretRequests

  def execute(%{agent_id: agent_id, name: name} = args, _assigns) do
    why = Map.get(args, :why)

    case SecretRequests.request(agent_id, name, why) do
      {:ok, key} ->
        {:ok,
         "Secret stored as key `#{key}` (kept out of this chat). When you need the " <>
           "value, call `get_secret` with key `#{key}` — ideally to set an env var " <>
           "right before the command that needs it, not to print it."}

      {:cancelled} ->
        {:ok,
         "The user DECLINED to provide `#{name}` (they don't have it). Do NOT ask " <>
           "for it again — proceed without it, work around it, or tell the user what " <>
           "you can't do without it."}

      {:error, :timeout} ->
        {:ok,
         "The user did not submit `#{name}` in time. Don't keep waiting — proceed " <>
           "without it or ask again later only if it's essential."}
    end
  end
end
