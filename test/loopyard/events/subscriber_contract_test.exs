defmodule Loopyard.Events.SubscriberContractTest do
  @moduledoc """
  Audit-2 coverage gap #6 (via Move #3 MEDIUM #5): every LiveView
  subscribing to a typed event topic must implement every
  `on_<event>` callback — no silent drops. That contract is enforced
  by the ABSENCE of `@optional_callbacks` in the subscriber
  behaviours. If a future contributor re-adds `@optional_callbacks`
  to any of these modules, the Elixir compiler stops flagging
  missing `@impl` declarations, and an LV author can ship a
  handler-missing subscription that silently ignores events.

  This meta-test walks the behaviour modules and asserts none of
  them carry `@optional_callbacks`. If one shows up, the test
  fails loud enough to surface in CI.
  """
  use ExUnit.Case, async: true

  @subscriber_modules [
    Loopyard.Events.ChatAgent.Subscriber,
    Loopyard.Events.ChatAgentMessage.Subscriber,
    Loopyard.Events.DockerObserver.Subscriber,
    Loopyard.Events.Projects.Subscriber,
    Loopyard.Events.SourceSync.Subscriber,
    Loopyard.Events.Workspaces.Subscriber,
    Loopyard.Events.WorkspaceServices.Subscriber,
    Loopyard.Events.WorkspaceSetup.Subscriber,
    Loopyard.Events.Workstation.Subscriber
  ]

  describe "subscriber behaviours have NO @optional_callbacks" do
    for mod <- @subscriber_modules do
      test "#{inspect(mod)} declares zero optional callbacks" do
        # `module_info(:attributes)[:optional_callbacks]` returns a
        # list of `{fun, arity}` tuples if the module declared any;
        # nil (or [] for older Elixir) means none.
        mod = unquote(mod)
        attrs = mod.module_info(:attributes)
        optional = Keyword.get(attrs, :optional_callbacks, [])

        assert optional == [],
               "#{inspect(mod)} has @optional_callbacks #{inspect(optional)}. " <>
                 "Move #3 MEDIUM #5 (audit-2 coverage #6): subscriber behaviours " <>
                 "must NOT mark callbacks optional, or the 'missing callback = " <>
                 "compile warning' contract regresses silently. Subscribers that " <>
                 "don't care about an event should implement " <>
                 "`def on_x(_e, socket), do: {:noreply, socket}` — explicit opt-out, " <>
                 "not silent drop."
      end
    end

    test "the list of audited subscriber modules matches reality" do
      # Catch the "someone added a new subscriber behaviour but forgot
      # to include it in @subscriber_modules" drift case. Walk every
      # compiled module in the Loopyard.Events.* tree, keep the ones
      # named *.Subscriber, and compare.
      live =
        for {mod, _} <- :code.all_loaded(),
            is_atom(mod),
            mod |> Atom.to_string() |> String.starts_with?("Elixir.Loopyard.Events."),
            mod |> Atom.to_string() |> String.ends_with?(".Subscriber"),
            do: mod

      missing = live -- @subscriber_modules

      assert missing == [],
             "New subscriber behaviour(s) #{inspect(missing)} found but not in " <>
               "@subscriber_modules. Add them to the audit list so the @optional_callbacks " <>
               "contract covers them."
    end
  end
end
