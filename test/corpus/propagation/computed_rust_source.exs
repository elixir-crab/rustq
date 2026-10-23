defmodule RustQ.Corpus.Propagation.ComputedRustSource do
  @moduledoc "Propagation from callable metadata in a Rust source whose path is computed."

  use RustQ.Meta, rust_sources: [Path.expand("../../fixtures/external_callables.rs", __DIR__)]

  alias RustQ.Type, as: R

  @spec decode_color(R.term()) :: R.nif_result(R.path(:Color))
  defrust decode_color(term) do
    color = decode_as!(term, R.u32())
    {:ok, Color.from_argb(255, 0, 0, color)}
  end

  @spec draw(R.term(), R.slice({R.atom(), R.term()})) :: R.nif_result(R.unit())
  defrust draw(term, opts) do
    stroke_paint(decode_color(term), 1.0, opts)
    :ok
  end
end
