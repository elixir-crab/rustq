defmodule RustQ.Corpus.Macros.DefrustmacroItemCapture do
  @moduledoc """
  Item macro functions with plain arguments, calling a function the macro names, and an
  expression capture given as RustQ AST.
  """

  use RustQ.Meta

  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Type, as: R

  @spec add(R.u32(), R.u32()) :: R.nif_result(R.u32())
  defrust add(left, right) do
    {:ok, left + right}
  end

  defrustmacro offset_pair(
                 fn: outer(:ident),
                 inner_fn: inner(:ident),
                 base: base(:literal),
                 scale: scale(:expr)
               ) do
    @spec outer(R.u32()) :: R.nif_result(R.u32())
    defrust outer(value) do
      inner(value * scale, base)
    end

    @spec inner(R.u32(), R.u32()) :: R.nif_result(R.u32())
    defrust inner(value, offset) do
      add(value, offset)
    end
  end

  def __rustq_corpus_fragments__ do
    [
      MetaAST.function!(__MODULE__, :add),
      MetaAST.macro_item!(__MODULE__, :offset_pair),
      MetaAST.macro_call!(__MODULE__, :offset_pair,
        fn: :offset_by_ten,
        inner_fn: :offset_by,
        base: 10,
        scale: A.add(A.lit(1), A.lit(2))
      )
    ]
  end
end
