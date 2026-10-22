defmodule RustQ.Codegen.DispatchTest do
  use ExUnit.Case,
    async: true,
    parameterize: [
      %{category: :item, function_name: :decode_ast_item},
      %{category: :type, function_name: :decode_ast_type},
      %{category: :pat, function_name: :decode_ast_pat},
      %{category: :stmt, function_name: :decode_ast_stmt},
      %{category: :expr, function_name: :decode_ast_expr}
    ]

  alias RustQ.Codegen.Dispatch
  alias RustQ.Rust.AST.{Function, Match, Path, PatPath, Return}
  alias RustQ.Rust.AST.Schema

  test "dispatch covers its externally decodable schema category", %{
    category: category,
    function_name: function_name
  } do
    assert %Function{body: [%Return{expr: %Match{arms: arms}}]} =
             Enum.find(Dispatch.asts(), &(&1.name == function_name))

    actual_consts =
      arms
      |> Enum.flat_map(fn
        %{pattern: %PatPath{path: %Path{parts: [:ast_modules, rust_const]}}} -> [rust_const]
        _badarg_arm -> []
      end)
      |> MapSet.new()

    expected_consts =
      category
      |> Schema.nodes()
      |> Enum.map(& &1.rust_const)
      |> MapSet.new()

    assert actual_consts == expected_consts
  end
end
