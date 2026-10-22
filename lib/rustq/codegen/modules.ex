defmodule RustQ.Codegen.Modules do
  @moduledoc """
  Builds the `atoms` and AST-module constant modules of `generated_ast.rs`, naming each
  RustQ AST node's Elixir module so native code can tell node terms apart.
  """

  alias RustQ.Codegen.ModuleHelpers
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.Schema

  def asts do
    [
      atoms_module(),
      ast_modules_module(),
      ModuleHelpers.asts()
    ]
  end

  defp atoms_module do
    A.module(
      :atoms,
      [
        A.macro_item_call([:rustler, :atoms], [:ok, :error])
      ],
      vis: :crate
    )
  end

  defp ast_modules_module do
    constants =
      Schema.nodes()
      |> Enum.reject(
        &(&1.name in [:arm, :attribute, :derive, :function_arg, :struct_field, :enum_variant])
      )
      |> Enum.map(fn node ->
        A.const(node.rust_const, {:ref, :str}, node.rust_module, vis: :crate)
      end)

    A.module(:ast_modules, constants, vis: :crate)
  end
end
