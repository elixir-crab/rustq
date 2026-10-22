defmodule RustQ.Corpus.Propagation.CallArgument do
  @moduledoc "Argument-position propagation inferred from local callable metadata."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec decode(term()) :: R.nif_result(R.u32())
  defrust decode(atom) do
    decode_as!(atom, R.u32())
  end

  @spec consume(R.u32()) :: R.nif_result(R.unit())
  defrust consume(value) do
    _copy = value
    :ok
  end

  @spec run(term()) :: R.nif_result(R.unit())
  defrust run(atom) do
    consume(decode(atom))
    :ok
  end
end
