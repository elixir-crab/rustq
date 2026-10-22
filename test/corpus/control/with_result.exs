defmodule RustQ.Corpus.Control.WithResult do
  @moduledoc "Nested with lowering without synthetic if true blocks."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec decode_a(R.u32()) :: R.nif_result(R.u32())
  defrust decode_a(term) do
    case term do
      1 -> {:ok, 10}
      _ -> {:error, badarg()}
    end
  end

  @spec decode_b(R.u32()) :: R.nif_result(R.u32())
  defrust decode_b(term) do
    case term do
      2 -> {:ok, 20}
      _ -> {:error, badarg()}
    end
  end

  @spec decode(R.u32()) :: R.nif_result(R.u32())
  defrust decode(term) do
    with {:error, _a_reason} <- decode_a(term),
         {:error, _b_reason} <- decode_b(term) do
      {:error, badarg()}
    else
      {:ok, value} -> {:ok, value + 1}
      {:error, _reason} -> {:error, badarg()}
    end
  end
end
