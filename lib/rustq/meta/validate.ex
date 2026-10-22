defmodule RustQ.Meta.Validate do
  @moduledoc """
  Checks that a generated item is valid Rust by rendering it and parsing the result with syn,
  raising when it does not parse.
  """

  alias RustQ.Rust
  alias RustQ.Rust.AST

  def item_ast(%AST.Function{} = item), do: ast_item(item)
  def item_ast(%AST.Module{} = item), do: ast_item(item)
  def item_ast(%AST.MacroItem{} = item), do: ast_item(item)
  def item_ast(%AST.Impl{} = item), do: ast_item(item)
  def item_ast(%AST.Struct{} = item), do: ast_item(item)
  def item_ast(%AST.Enum{} = item), do: ast_item(item)
  def item_ast(%AST.TypeAlias{} = item), do: ast_item(item)
  def item_ast(%AST.MacroRules{} = item), do: ast_item(item)

  def ast_item(item) do
    RustQ.parse_fragment!(:item, Rust.render(item))
  end
end
