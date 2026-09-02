# Dialyzer findings reviewed and kept on purpose. `list_unused_filters: true`
# (mix.exs) fails the run if an entry here stops matching — so a fixed site
# must be removed from this list, and the list can never silently rot.
[
  # `Priority.unix_ms(_)` is a defensive fallback: `Item.raised_at` is typed
  # `DateTime.t()` (both production constructors always set it), but the
  # struct default is nil and a bare `%Item{}` (tests, a future constructor)
  # must sort last rather than crash the inbox sort. Dialyzer reads the spec
  # and calls the clause unreachable.
  {"lib/loopyard/notifications/priority.ex", :pattern_match_cov}
]
