defmodule RustQ.Corpus.Macros.RemoteCall do
  @moduledoc "Remote Rust macro call lowering."

  use RustQ.Meta

  alias RustQ.Type, as: R

  @spec log_value(R.u32()) :: R.nif_result(R.unit())
  defrust log_value(value) do
    Debug.trace!(value)
    :ok
  end
end
