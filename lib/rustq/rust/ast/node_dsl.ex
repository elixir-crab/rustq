defmodule RustQ.Rust.AST.NodeDSL do
  @moduledoc """
  `defnode/4` declares a RustQ AST node module: its struct, typespec, and the category
  (`:item`, `:stmt`, `:expr`, `:pat`, `:type`, …) that `RustQ.Rust.AST.Schema` and
  rendering dispatch on.
  """

  defmacro defnode(name, category, fields, opts \\ []) do
    type_ast = opts |> Keyword.fetch!(:type) |> quoted_type_ast()

    quote do
      defmodule unquote(name) do
        @moduledoc "Structural RustQ AST node. Prefer the focused builder modules for construction."
        defstruct unquote(fields)

        @rustq_ast_category unquote(category)
        def __rustq_ast_category__, do: @rustq_ast_category

        @type t :: unquote(type_ast)
      end
    end
  end

  defp quoted_type_ast({:quote, _meta, [[do: ast]]}), do: ast
  defp quoted_type_ast(ast), do: ast
end
