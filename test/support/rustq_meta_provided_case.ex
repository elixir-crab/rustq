defmodule RustQ.Meta.ProvidedCase do
  @moduledoc """
  Test fixture module that provides the Rust beside it, as a library ships a Rust runtime its
  generated code includes.
  """

  use RustQ.Meta, provides: ["rustq_meta_provided_case.rs"]
end
