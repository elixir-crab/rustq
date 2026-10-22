defmodule RustQ.Corpus.Propagation.MutRefVecPush do
  @moduledoc "Propagate fallible call arguments passed to push on a mutable Vec reference."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec make_term() :: R.u32()
  defrust(make_term(), do: 0)

  @spec decode_value() :: R.nif_result(R.u32())
  defrust(decode_value(), do: {:ok, make_term()})

  @spec run(R.mut_ref(R.vec(R.u32()))) :: R.nif_result(R.unit())
  defrust run(values) do
    values.push(decode_value())
    :ok
  end
end
