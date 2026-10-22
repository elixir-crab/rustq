defmodule RustQ.Corpus.Propagation.ImplAsRef do
  @moduledoc "Propagate fallible values into impl AsRef<T> arguments."

  use RustQ.Meta, rust_sources: ["test/fixtures/impl_as_ref.rs"]

  alias RustQ.Type, as: R

  @spec decode(term()) :: R.nif_result(R.path(:Picture))
  defrust decode(_term) do
    {:ok, Picture.default()}
  end

  @spec run(term()) :: R.nif_result(R.unit())
  defrust run(term) do
    consume(decode(term))
    :ok
  end
end
