defmodule RustQ.Corpus.Types.Struct do
  @moduledoc "Struct emission from Elixir @type metadata."

  use RustQ.Meta

  alias RustQ.Type, as: R

  defmodule Point do
    defstruct [:x, :y]
  end

  @type point :: %Point{x: R.f32(), y: R.f32()}

  @spec origin() :: point()
  defrust origin() do
    struct_literal(Point, x: 0.0, y: 0.0)
  end
end
