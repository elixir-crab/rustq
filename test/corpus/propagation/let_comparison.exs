defmodule RustQ.Corpus.Propagation.LetComparison do
  @moduledoc "Propagate a fallible let RHS when downstream comparisons use the success value."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @type field :: %{required(:id) => R.u32()}

  @spec read_id() :: R.nif_result(R.u32())
  defrust(read_id(), do: {:ok, 0})

  @spec run(R.slice(field())) :: R.nif_result(R.unit())
  defrust run(fields) do
    field_id = read_id()

    if field_id == 0 do
      :ok
    else
      case fields.binary_search_by_key(field_id, fn field -> field.id end) do
        {:ok, _index} -> :ok
        {:error, _index} -> {:error, badarg()}
      end
    end
  end
end
