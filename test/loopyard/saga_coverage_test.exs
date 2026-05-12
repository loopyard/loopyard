defmodule Loopyard.SagaCoverageTest do
  @moduledoc """
  Static enforcement for Move #7a's "every multi-step operation goes
  through Saga.run/1" guarantee.

  The check is explicit-allowlist, not AST heuristic. Static code
  analysis of "this looks like a multi-step operation" has too many
  false positives to fail a CI run on — any compose/multi-call
  sequence would trip it. Instead we maintain a hand-curated list of
  **known multi-step state-mutating operations** in the codebase, and
  this test asserts each one either:

    1. contains a direct call to `Loopyard.Saga.run` in its own
       function body, OR
    2. is explicitly allow-listed with a reason (for operations that
       can't be cleanly saga'd — see module doc of
       `Loopyard.Saga` for the criteria).

  Adding a new multi-step operation in the future means adding an
  entry here. If you write the feature without a saga, CI fails. If
  sagaing is the wrong fit (true fire-and-forget, best-effort
  teardown, etc.), document WHY in the `@non_saga_reasons` map.

  ## Why this, not an AST scan

  An AST scan for "three or more state mutations in a row" catches
  the shapes we want but also every compose-style helper, every
  pipeline of `Map.put`s, every test setup. The signal gets drowned
  in the noise and gets disabled within a week. An explicit list is
  boring and discoverable: the next contributor reading this test
  sees the scope directly.
  """
  use ExUnit.Case, async: true

  # Operations that MUST use Saga.run/2. (file, function_substring).
  # The substring is used with Regex.compile just to avoid pinning
  # on line-number sensitivity or exact whitespace.
  @saga_required [
    {"lib/loopyard/agent_boot.ex", "def boot("},
    {"lib/loopyard/workspace_supervisor.ex", "defp rebuild_saga("}
  ]

  # Multi-step operations that intentionally are NOT sagas, with
  # reasons. If you're adding to this list, document why the saga
  # shape is wrong for the operation.
  @non_saga_reasons %{
    # Destructor is a best-effort teardown: each step is soft-fail-
    # and-continue by design. A saga would "rollback" deletes (i.e.
    # re-create containers), which is exactly the wrong shape.
    "lib/loopyard/workspace/destructor.ex" =>
      "Best-effort teardown — each step is idempotent + soft-fail. " <>
        "Rollback would re-create deleted resources.",

    # ServiceManager.do_start is essentially a single compose up + a
    # couple of book-keeping broadcasts. Its failure modes are
    # reported to the caller and no half-state persists (ETS cache
    # + broadcasts fire the same way on success and failure).
    "lib/loopyard/workspace/service_manager.ex" =>
      "Single compose-up + broadcasts. Partial-success state not " <>
        "observable (ETS cache + broadcasts are eventually consistent).",

    # ChatAgent.remove_agent/1 is best-effort destruction, same
    # shape as Workspace.Destructor: the user explicitly asked to
    # delete the agent. If the ETF-log append fails after we've
    # broadcast :destroying, rolling back would mean un-destroying
    # the agent (re-creating ETS summary, reviving sidebar entry)
    # against the user's stated intent. The reconciler + explicit
    # retry on next remove_agent call are the right backstops;
    # saga rollback would create a worse UX than the current
    # "pinned at :destroying until next reconcile" failure mode.
    "lib/loopyard/chat_agent.ex" =>
      "Best-effort destruction of agent — user asked to delete. " <>
        "Rollback would re-create state the user explicitly removed. " <>
        "Reconciler cleans up any stuck :destroying rows."
  }

  describe "multi-step operations use Saga.run" do
    test "every operation in @saga_required calls Saga.run/2" do
      for {relative_path, function_pattern} <- @saga_required do
        path = Path.join([File.cwd!(), relative_path])
        assert File.exists?(path), "File #{relative_path} not found"

        source = File.read!(path)

        # Assert the function is present in the file
        assert source =~ function_pattern,
               "Expected function matching #{inspect(function_pattern)} in #{relative_path}"

        # Extract the function body (from function definition to next
        # `end` at the same indentation level) and check it uses Saga.
        function_body = extract_function_body(source, function_pattern)

        assert function_body =~ ~r/Saga\.run/,
               """
               Function matching #{inspect(function_pattern)} in #{relative_path}
               is listed in @saga_required but does not call Saga.run/2.

               If this is intentional (e.g. operation can't be cleanly saga'd),
               move it to @non_saga_reasons with a justification.

               If it's a migration bug, wrap the multi-step flow in Saga.run/2.
               """
      end
    end

    test "operations in @non_saga_reasons have a justification" do
      for {path, reason} <- @non_saga_reasons do
        assert is_binary(reason) and byte_size(reason) > 40,
               "Non-saga justification for #{path} is too short — explain why sagaing is the wrong fit (>40 chars)"

        full_path = Path.join([File.cwd!(), path])

        assert File.exists?(full_path),
               "Non-saga-allowlist entry #{path} points at a missing file. Remove the entry or fix the path."
      end
    end
  end

  # Naive but sufficient for our scale: find the line that matches
  # the pattern, then read forward collecting lines until we see an
  # `end` at the same or shallower indentation than the `def` line.
  # For `defmodule`-contained functions (2-space indent) this maps to
  # an `end` at 2-space indent.
  defp extract_function_body(source, function_pattern) do
    lines = String.split(source, "\n")

    case find_def_line(lines, function_pattern) do
      nil ->
        ""

      {def_line_idx, def_indent} ->
        lines
        |> Enum.drop(def_line_idx)
        |> Enum.reduce_while([], fn line, acc ->
          cond do
            acc == [] ->
              {:cont, [line]}

            String.match?(line, ~r/^#{def_indent}end\s*$/) ->
              {:halt, Enum.reverse([line | acc])}

            true ->
              {:cont, [line | acc]}
          end
        end)
        |> Enum.join("\n")
    end
  end

  defp find_def_line(lines, function_pattern) do
    lines
    |> Enum.with_index()
    |> Enum.find_value(fn {line, idx} ->
      if String.contains?(line, function_pattern) do
        # Indent = leading spaces of the line
        [indent | _] = Regex.run(~r/^(\s*)/, line) || [""]
        {idx, indent}
      end
    end)
  end
end
