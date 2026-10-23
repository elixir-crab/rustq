defmodule RustQ.Corpus.Mutation.IndexAssignment do
  @moduledoc "Assigning a fallible call into an element of an owned vector."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec checked(R.u32()) :: R.nif_result(R.u32())
  defrust checked(value) do
    if value > 100 do
      {:error, badarg()}
    else
      {:ok, value}
    end
  end

  @spec replace(R.vec(R.u32()), R.usize(), R.u32()) :: R.nif_result(R.vec(R.u32()))
  defrust replace(values, index, value) do
    assign!(index(values, index), checked(value))
    {:ok, values}
  end
end
