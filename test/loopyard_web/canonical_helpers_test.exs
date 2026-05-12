defmodule LoopyardWeb.CanonicalHelpersTest do
  @moduledoc """
  Fails the build if any of the canonical helpers in `LoopyardWeb.Format`
  get re-defined elsewhere. The Format module is auto-imported into every
  LiveView, component, and HTML module via `LoopyardWeb.html_helpers/0`,
  so duplicating one of its functions in a LiveView's `defp` (or
  another module's `def`) is dead code at best and a drift bug waiting
  to happen at worst.

  We previously had FOUR copies of `shorten_path/1` and TWO of
  `project_location/1` — each implementation slightly different — until
  this audit. This test pins that they stay in one place.

  How to fix a failure:
  - Delete the offending `defp shorten_path` (or whatever).
  - The Format function is already auto-imported; just call it.
  - For non-LiveView modules (like `Components.ToolSummary`), add an
    explicit `import LoopyardWeb.Format, only: [shorten_path: 1]`.

  How to add a new canonical helper:
  - Put it in `LoopyardWeb.Format` (one definition).
  - Add its `{name, arity}` to @canonical below.
  - The next time anyone re-defps it, the build breaks.
  """
  use ExUnit.Case, async: true

  # The function name + arity of every helper in LoopyardWeb.Format.
  # If you add a new function to Format, add it here too.
  @canonical [
    {:shorten_path, 1},
    {:project_location, 1},
    {:format_bytes, 1},
    {:format_number, 1},
    {:format_rss, 1},
    {:mem_bar_pct, 1},
    {:load_color, 2},
    {:log_level_class, 1}
  ]

  # The single source-of-truth file. Definitions here are expected.
  @canonical_source "lib/loopyard_web/format.ex"

  # AST-walks every lib/**/*.ex file (200+ files). Fast in isolation
  # but under full-suite I/O contention can exceed the 2s default.
  @tag timeout: 10_000
  test "canonical helpers from LoopyardWeb.Format are defined exactly once" do
    duplicates = find_duplicates()

    if duplicates != [] do
      formatted =
        duplicates
        |> Enum.map_join("\n", fn {name, arity, file, line} ->
          "  #{file}:#{line}  redefines #{name}/#{arity}"
        end)

      flunk("""
      Found duplicate definitions of canonical helpers from LoopyardWeb.Format.
      These are auto-imported into every LiveView and component — re-defining
      them is dead code (the local def shadows the import) and a drift bug
      waiting to happen.

      #{formatted}

      Delete the local def and use the import. For non-LiveView modules,
      add `import LoopyardWeb.Format, only: [#{example_only()}]`.
      See CLAUDE.md → "Display formatters and tiny UI primitives".
      """)
    end
  end

  defp find_duplicates do
    Path.wildcard("lib/**/*.ex")
    |> Enum.reject(&(&1 == @canonical_source))
    |> Enum.flat_map(&scan_file/1)
  end

  defp scan_file(path) do
    case path |> File.read!() |> Code.string_to_quoted() do
      {:ok, ast} -> collect_def_names(ast, path)
      _ -> []
    end
  end

  defp collect_def_names(ast, path) do
    {_, defs} =
      Macro.prewalk(ast, [], fn
        # def name(args) and defp name(args) — match the head form.
        {marker, meta, [{name, _, args} | _]} = node, acc
        when marker in [:def, :defp] and is_atom(name) and is_list(args) ->
          arity = length(args)

          if {name, arity} in @canonical do
            line = Keyword.get(meta, :line, 0)
            {node, [{name, arity, path, line} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp example_only do
    @canonical |> Enum.take(1) |> Enum.map_join(", ", fn {n, a} -> "#{n}: #{a}" end)
  end

  describe "the scanner itself" do
    test "catches a duplicated shorten_path/1 in a non-canonical file" do
      offending = """
      defmodule FakeMod do
        defp shorten_path(path) do
          path
        end
      end
      """

      assert [{:shorten_path, 1, "<test>", _line} | _] = scan_string(offending)
    end

    test "ignores files that don't redefine canonical helpers" do
      clean = """
      defmodule FakeMod do
        def helper(x), do: x + 1
        defp internal(_), do: :ok
      end
      """

      assert scan_string(clean) == []
    end

    test "ignores arity mismatches" do
      # shorten_path/2 isn't a canonical function — only /1 is.
      clean = """
      defmodule FakeMod do
        defp shorten_path(a, b), do: a <> b
      end
      """

      assert scan_string(clean) == []
    end

    defp scan_string(source) do
      {:ok, ast} = Code.string_to_quoted(source)
      collect_def_names(ast, "<test>")
    end
  end
end
