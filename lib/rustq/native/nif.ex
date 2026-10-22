defmodule RustQ.Native.Nif do
  @moduledoc """
  Loads RustQ's own native library, `rustq_nif`, which parses, renders, and inspects Rust
  with `syn` and `prettyplease`. Each function is replaced by its NIF when the library loads.
  """

  use Rustler, otp_app: :rustq, crate: "rustq_nif"

  @doc "Checks that Rust source parses as a file, returning `:ok` or its parse errors."
  def parse(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Renders a Rust template with its placeholder bindings and splices substituted."
  def render(_source, _bindings, _splices), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Renders one RustQ AST item as formatted Rust source."
  def render_ast(_ast), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns how Rust writes `name` where `context` (`"name"`, `"segment"`, or `"expr"`) expects
  it, or `{:error, message}` when it cannot.
  """
  def rust_identifier(_name, _context), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Parses a Rust file into the item metadata `RustQ.Syn` decodes."
  def syn_inspect(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Like `syn_inspect/1`, after rewriting the unstable syntax the Rust standard library uses."
  def syn_inspect_unstable(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Lists the atoms Rust source references through the named Rustler atoms module."
  def syn_atom_references(_source, _module), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Lists the method names Rust source calls."
  def syn_method_references(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Lists the receiver and method of each method call in Rust source."
  def syn_method_calls(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Lists the variants of the enum named `enum_name` in Rust source."
  def syn_enum_variants(_source, _enum_name), do: :erlang.nif_error(:nif_not_loaded)
end
