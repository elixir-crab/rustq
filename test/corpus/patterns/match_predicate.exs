defmodule RustQ.Corpus.Patterns.MatchPredicate do
  @moduledoc "`match?/2` answers whether a value matches a pattern."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @type origin :: R.enum(assignment: [], literal: [])

  @spec assigned?(origin(), R.u32()) :: boolean()
  defrust assigned?(origin, field) do
    match?({:assignment, 7}, {origin, field})
  end
end
