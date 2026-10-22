defmodule RustQ.Codegen.Decoders do
  @moduledoc """
  Collects the generated `syn` decoders for each RustQ AST category (items, types,
  patterns, statements, expressions, and match arms) into one list of Rust items.
  """

  alias RustQ.Codegen.Decoders.{Arm, Expr, Item, Pat, Stmt, Type}

  def asts do
    [
      Item.asts(),
      Type.asts(),
      Pat.asts(),
      Stmt.asts(),
      Arm.asts(),
      Expr.asts()
    ]
    |> List.flatten()
  end
end
