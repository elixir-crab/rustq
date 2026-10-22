defmodule RustQ.Clippy do
  @moduledoc """
  Paths of Clippy lints, for `#[allow(...)]` attributes on generated Rust.
  """

  alias RustQ.Rust.AST

  @doc """
  Returns the `clippy::redundant_field_names` lint path.
  """
  @spec redundant_field_names() :: AST.Path.t()
  def redundant_field_names do
    lint(:redundant_field_names)
  end

  @doc """
  Returns a Clippy lint path for `name`.
  """
  @spec lint(atom() | String.t()) :: AST.Path.t()
  def lint(name) do
    %AST.Path{parts: [:clippy, name]}
  end
end
