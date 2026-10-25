defmodule RustQ.Meta.ProvidedCase do
  @moduledoc """
  Test fixture module that provides `templates/provided_case.rs`, as a library ships a Rust
  runtime its generated code includes, and maps the Rust modules its generated code defines.
  """

  use RustQ.Meta

  defrustmod(__MODULE__, as: [:provided])
  defrustmod(Limits, as: [:provided_limits])
end
