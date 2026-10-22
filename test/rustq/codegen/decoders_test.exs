defmodule RustQ.Codegen.DecodersTest do
  alias RustQ.Rust.AST.Schema

  expected_decoders =
    Enum.map(Schema.nodes(:item), &String.to_atom("decode_ast_#{&1.name}")) ++
      [:decode_function_arg, :decode_struct_field, :decode_enum_variant] ++
      Enum.map(Schema.nodes(:type), &String.to_atom("decode_#{&1.name}")) ++
      Enum.map(Schema.nodes(:expr), &String.to_atom("decode_expr_#{&1.name}")) ++
      Enum.map(Schema.nodes(:stmt), &String.to_atom("decode_stmt_#{&1.name}")) ++
      (Schema.nodes(:pat)
       |> Enum.reject(&(&1.name == :pat_atom_guard))
       |> Enum.map(&String.to_atom("decode_#{&1.name}")))

  use ExUnit.Case,
    async: true,
    parameterize: Enum.map(expected_decoders, &%{decoder_name: &1})

  alias RustQ.Codegen.Decoders

  test "generated decoder exists", %{decoder_name: decoder_name} do
    assert Enum.any?(Decoders.asts(), &(&1.name == decoder_name))
  end
end
