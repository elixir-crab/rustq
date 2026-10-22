defmodule RustQ.Codegen.Decoders.TypeTest do
  use ExUnit.Case,
    async: true,
    parameterize:
      Enum.map(
        [:decode_type_option, :decode_type_result, :decode_type_nif_result, :decode_type_vec],
        &%{decoder_name: &1}
      )

  alias RustQ.Codegen.Decoders.Type, as: TypeDecoders
  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Rust.AST.{Function, Path, PathCall, Return, VecLiteral}

  test "uses generic type construction", %{decoder_name: name} do
    assert %Function{body: body} =
             TypeDecoders
             |> MetaAST.functions()
             |> Enum.find(&(&1.name == name))

    assert %Return{
             expr: %PathCall{
               path: %Path{parts: [:super, :parse_type_generic]},
               args: [_path, %VecLiteral{}]
             }
           } = List.last(body)
  end
end
