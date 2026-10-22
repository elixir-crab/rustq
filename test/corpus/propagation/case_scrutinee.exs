defmodule RustQ.Corpus.Propagation.CaseScrutinee do
  @moduledoc "Fallible case scrutinees propagate before matching inner patterns."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec read_field() :: R.nif_result(R.u32())
  defrust read_field() do
    {:ok, 1}
  end

  @spec skip_field() :: R.nif_result(R.unit())
  defrust skip_field() do
    case read_field() do
      0 ->
        :ok

      _field_id ->
        {:error, badarg()}
    end
  end
end
