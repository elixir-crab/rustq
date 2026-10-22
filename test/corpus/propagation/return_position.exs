defmodule RustQ.Corpus.Propagation.ReturnPosition do
  @moduledoc "Return-position propagation inferred from local specs."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec decode(term()) :: R.nif_result(R.u32())
  defrust decode(atom) do
    decode_as!(atom, R.u32())
  end

  @spec use_decode(term()) :: R.nif_result(R.u32())
  defrust use_decode(atom) do
    value = decode(atom)
    {:ok, value}
  end
end
