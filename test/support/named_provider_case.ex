defmodule RustQ.Meta.NamedProviderCase do
  @moduledoc """
  Test fixture module that names the Rust file it provides, which is named after another module.
  """

  use RustQ.Meta, provides: ["templates/provided_case.rs"]
end
