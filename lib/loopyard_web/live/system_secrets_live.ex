defmodule LoopyardWeb.SystemSecretsLive do
  @moduledoc """
  Admin surface for `Loopyard.Secrets`.

  The secret store (`~/.loopyard/secrets.json`) has full CRUD in the backend,
  but the only way a value reached it was reactively — an agent blocks on a
  `secret_card` in chat and the user types it in. That left no way to SEE what's
  stored, pre-seed a credential before an agent needs it, rotate a leaked token,
  re-scope, or delete. This page is that admin UI the `Secrets` moduledoc always
  pointed at (`list/0` / `get/1` are documented as "intended for admin UIs").

  Values are masked by default; "Reveal" fetches the plaintext on demand
  (`get/1`) so a shoulder-surfer doesn't see every token at a glance. This is a
  local-only, unauthenticated surface by design (see the auth-deferral note) —
  it trusts whoever can already reach the server.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Secrets

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_iex()
     |> assign(:revealed, %{})
     |> assign(:form, empty_form())
     |> assign_secrets()}
  end

  defp assign_iex(socket) do
    if connected?(socket),
      do: subscribe_iex(socket),
      else: assign(socket, :iex_session, %{level: nil})
  end

  defp assign_secrets(socket) do
    assign(socket, :secrets, Enum.sort_by(Secrets.list(), & &1.key))
  end

  defp empty_form, do: %{"key" => "", "name" => "", "value" => "", "scope" => ""}

  @impl true
  def handle_event("save", %{"secret" => params}, socket) do
    key = String.trim(params["key"] || "")
    value = params["value"] || ""

    cond do
      key == "" ->
        {:noreply, put_flash(socket, :error, "A key is required.")}

      value == "" ->
        {:noreply, put_flash(socket, :error, "A value is required.")}

      true ->
        name = blank_to_nil(params["name"]) || key
        scope = parse_scope(params["scope"])
        existed? = Enum.any?(socket.assigns.secrets, &(&1.key == key))
        Secrets.put(key, name, value, scope)

        {:noreply,
         socket
         |> assign(:form, empty_form())
         |> assign_secrets()
         |> put_flash(:info, if(existed?, do: "Rotated \"#{key}\".", else: "Saved \"#{key}\"."))}
    end
  end

  def handle_event("reveal", %{"key" => key}, socket) do
    case Secrets.get(key) do
      {:ok, value} ->
        {:noreply, assign(socket, :revealed, Map.put(socket.assigns.revealed, key, value))}

      :not_found ->
        {:noreply, put_flash(socket, :error, "Secret \"#{key}\" not found.")}
    end
  end

  def handle_event("hide", %{"key" => key}, socket) do
    {:noreply, assign(socket, :revealed, Map.delete(socket.assigns.revealed, key))}
  end

  def handle_event("delete", %{"key" => key}, socket) do
    Secrets.delete(key)

    {:noreply,
     socket
     |> assign(:revealed, Map.delete(socket.assigns.revealed, key))
     |> assign_secrets()
     |> put_flash(:info, "Deleted \"#{key}\".")}
  end

  # "id-a, id-b" → ["id-a", "id-b"]; blank → [] (global).
  defp parse_scope(nil), do: []

  defp parse_scope(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(str), do: if(String.trim(str) == "", do: nil, else: String.trim(str))

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      mode={:system}
      breadcrumbs={[{"Loopyard", "/"}, {"System", "/system"}, {"Secrets", nil}]}
      iex_session={@iex_session}
      max_width={:xl}
      flash={@flash}
    >
      <div class="space-y-8">
        <section>
          <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-1">
            Secrets <span class="text-zinc-400 font-normal">({length(@secrets)})</span>
          </h2>
          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-4 max-w-2xl">
            Named credentials in <code class="font-mono">~/.loopyard/secrets.json</code>. Agents
            fetch these at runtime by name (never pre-injected as env vars). A secret with no
            scope is <strong>global</strong> — visible to every agent; a scoped secret is only
            visible to the workspace or project IDs listed.
          </p>

          <div :if={@secrets == []} class="text-sm text-zinc-500 dark:text-zinc-400 italic">
            No secrets stored yet. Add one below, or an agent will prompt for one when it needs it.
          </div>

          <div
            :if={@secrets != []}
            class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 overflow-hidden"
          >
            <table class="w-full text-sm">
              <thead>
                <tr class="text-left text-zinc-500 dark:text-zinc-400 bg-zinc-100/50 dark:bg-zinc-800/30">
                  <th class="px-3 py-2 font-medium">Key</th>
                  <th class="px-3 py-2 font-medium">Name</th>
                  <th class="px-3 py-2 font-medium">Scope</th>
                  <th class="px-3 py-2 font-medium">Value</th>
                  <th class="px-3 py-2 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={s <- @secrets}
                  class="border-t border-zinc-200 dark:border-zinc-700/40 align-top"
                >
                  <td class="px-3 py-2 font-mono font-semibold text-zinc-800 dark:text-zinc-200">
                    {s.key}
                  </td>
                  <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400">{s.name}</td>
                  <td class="px-3 py-2">
                    <span
                      :if={s.scope == []}
                      class="inline-flex items-center rounded-sm px-1.5 py-0.5 text-xs font-medium bg-amber-100 dark:bg-amber-500/15 text-amber-700 dark:text-amber-400"
                    >
                      global
                    </span>
                    <span
                      :if={s.scope != []}
                      class="font-mono text-xs text-zinc-500 dark:text-zinc-400"
                      title={Enum.join(s.scope, ", ")}
                    >
                      {Enum.join(s.scope, ", ")}
                    </span>
                  </td>
                  <td class="px-3 py-2 font-mono text-xs">
                    <span :if={@revealed[s.key]} class="text-zinc-800 dark:text-zinc-200 break-all">
                      {@revealed[s.key]}
                    </span>
                    <span :if={!@revealed[s.key]} class="text-zinc-500 dark:text-zinc-400 select-none">
                      ••••••••
                    </span>
                  </td>
                  <td class="px-3 py-2 text-right whitespace-nowrap">
                    <button
                      :if={!@revealed[s.key]}
                      phx-click="reveal"
                      phx-value-key={s.key}
                      class="text-xs font-medium text-zinc-500 hover:text-violet-600 dark:hover:text-violet-400"
                    >
                      Reveal
                    </button>
                    <button
                      :if={@revealed[s.key]}
                      phx-click="hide"
                      phx-value-key={s.key}
                      class="text-xs font-medium text-zinc-500 hover:text-violet-600 dark:hover:text-violet-400"
                    >
                      Hide
                    </button>
                    <span class="text-zinc-300 dark:text-zinc-600 mx-1">·</span>
                    <button
                      phx-click="delete"
                      phx-value-key={s.key}
                      data-confirm={"Delete secret \"#{s.key}\"? Agents relying on it will no longer be able to fetch it."}
                      class="text-xs font-medium text-zinc-500 hover:text-red-600 dark:hover:text-red-400"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section>
          <h3 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-1">
            Add / rotate
          </h3>
          <p class="text-xs text-zinc-500 dark:text-zinc-400 mb-3">
            Saving a key that already exists overwrites its value — that's how you rotate a token.
          </p>
          <form phx-submit="save" class="space-y-3 max-w-2xl">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="block">
                <span class="text-xs font-medium text-zinc-600 dark:text-zinc-400">Key</span>
                <input
                  name="secret[key]"
                  value={@form["key"]}
                  placeholder="GITHUB_TOKEN"
                  autocomplete="off"
                  class="mt-1 w-full rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm font-mono text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                />
              </label>
              <label class="block">
                <span class="text-xs font-medium text-zinc-600 dark:text-zinc-400">
                  Display name <span class="text-zinc-400 font-normal">(optional)</span>
                </span>
                <input
                  name="secret[name]"
                  value={@form["name"]}
                  placeholder="GitHub personal access token"
                  autocomplete="off"
                  class="mt-1 w-full rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                />
              </label>
            </div>
            <label class="block">
              <span class="text-xs font-medium text-zinc-600 dark:text-zinc-400">Value</span>
              <input
                name="secret[value]"
                type="password"
                value={@form["value"]}
                placeholder="ghp_…"
                autocomplete="off"
                class="mt-1 w-full rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm font-mono text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
              />
            </label>
            <label class="block">
              <span class="text-xs font-medium text-zinc-600 dark:text-zinc-400">
                Scope <span class="text-zinc-400 font-normal">(optional — blank = global)</span>
              </span>
              <input
                name="secret[scope]"
                value={@form["scope"]}
                placeholder="workspace-id, project-id (comma-separated)"
                autocomplete="off"
                class="mt-1 w-full rounded-sm border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm font-mono text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
              />
              <span class="text-xs text-zinc-500 dark:text-zinc-400 mt-1 block">
                Restrict which workspaces / projects can read this secret. Leave blank so every
                agent can use it.
              </span>
            </label>
            <button
              type="submit"
              class="inline-flex items-center rounded-sm bg-violet-600 hover:bg-violet-700 text-white px-4 py-2 text-sm font-medium transition-colors"
            >
              Save secret
            </button>
          </form>
        </section>
      </div>
    </.page_shell>
    """
  end
end
