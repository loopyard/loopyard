%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/"],
        excluded: [~r/deps/, ~r/_build/]
      },
      plugins: [],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      checks: %{
        enabled: [
          # Consistency
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          # Design
          {Credo.Check.Design.AliasUsage, false},
          {Credo.Check.Design.DuplicatedCode, false},
          # Report-only (exit_status: 0): a TODO/FIXME is a note, not a bug.
          {Credo.Check.Design.TagFIXME, [exit_status: 0]},
          {Credo.Check.Design.TagTODO, [exit_status: 0]},

          # Readability
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [max_length: 140]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},

          # Refactoring
          {Credo.Check.Refactor.CondStatements, []},
          # Structure checks are report-only: the invariants test's module-size
          # ratchet is the structural gate; these are hints for the next refactor,
          # never a reason to fail a build that is otherwise clean.
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15, exit_status: 0]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 8, exit_status: 0]},
          {Credo.Check.Refactor.LongQuoteBlocks, false},
          {Credo.Check.Refactor.MapInto, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 4, exit_status: 0]},
          {Credo.Check.Refactor.UnlessWithElse, []},

          # Warnings
          # --- The "catastrophic stupid error" class: each of these is a bug
          # that ships silently and bites in production, never a style nit.
          # Atoms from user input exhaust the VM; shell strings built from
          # input inject; Mix.env / config-in-attribute freeze dev values into
          # a release; a test file with the wrong extension never runs.
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []}
        ]
      }
    }
  ]
}
