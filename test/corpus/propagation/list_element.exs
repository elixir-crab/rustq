defmodule RustQ.Corpus.Propagation.ListElement do
  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec decode(R.term()) :: R.nif_result(R.path(:Color))
  defrust decode(term) do
    value = decode_as!(term, R.u32())
    {:ok, Color.from_argb(255, 0, 0, value)}
  end

  @spec consume(R.vec(R.path(:Color))) :: R.nif_result(R.unit())
  defrust(consume(_colors), do: :ok)

  @spec run(R.term()) :: R.nif_result(R.unit())
  defrust run(term) do
    consume([decode(term)])
    :ok
  end
end
