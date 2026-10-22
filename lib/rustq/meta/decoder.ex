defmodule RustQ.Meta.Decoder do
  @moduledoc """
  Builds the Rust that decodes BEAM terms into the structs and enums a module's types
  declare: struct fields, field decoders, and tagged enum decoder bodies.
  """

  alias RustQ.Meta.Type
  alias RustQ.Rust.{AST, Identifier}
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.PatternBuilder, as: P

  require A

  def struct_field_ast({name, %Type{} = type, :required}) do
    %AST.StructField{name: name, type: type.ast, vis: :pub}
  end

  def struct_field_ast({name, %Type{} = type, :optional}) do
    %AST.StructField{name: name, type: %AST.TypeOption{inner: type.ast}, vis: :pub}
  end

  def struct_decoder_field({name, _type, :required}) do
    {name, A.try(A.method(A.try(A.method(:term, :map_get, [atom_call(name)])), :decode))}
  end

  def struct_decoder_field({name, _type, :optional}) do
    {name,
     A.match A.method(:term, :map_get, [atom_call(name)]) do
       A.arm P.ok(:value) do
         A.return(A.some(A.try(A.method(:value, :decode))))
       end

       A.arm P.err(P.wildcard()) do
         A.return(A.none())
       end
     end}
  end

  def tuple_enum_decoder_body(rust_name, variants) do
    A.block do
      A.let(:struct_name, struct_name_expr())

      A.return do
        A.match A.method(:struct_name, :as_str) do
          Enum.map(variants, fn {tag, [%Type{meta: %{rust_name: variant_name}}]} ->
            A.arm P.lit("Elixir.#{variant_name}") do
              A.return do
                A.method(
                  A.call(
                    Identifier.atom!("decode_#{Macro.underscore(variant_name)}"),
                    [
                      :term
                    ]
                  ),
                  :map,
                  [A.path([rust_name, rust_variant(tag)])]
                )
              end
            end
          end) ++ [A.badarg_arm()]
        end
      end
    end
  end

  def struct_name_expr do
    A.try(A.method(A.try(A.method(:term, :map_get, [struct_atom_expr()])), :atom_to_string))
  end

  def struct_atom_expr do
    A.try(A.path_call([:rustler, :Atom, :from_str], [A.method(:term, :get_env), "__struct__"]))
  end

  def atom_call(name), do: A.path_call([:atoms, name])

  def rust_variant(value), do: value |> Atom.to_string() |> Macro.camelize()
end
