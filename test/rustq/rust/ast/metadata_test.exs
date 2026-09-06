defmodule RustQ.Rust.AST.MetadataTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.Metadata

  test "typed metadata preserves paths, escaped values and nesting" do
    args = [
      %Metadata.Path{parts: [:tool, :flag]},
      %Metadata.NameValue{parts: [:tool, :name], value: "quoted\"\\λ"},
      %Metadata.List{parts: [:tool, :nested], items: [%Metadata.Path{parts: [:inner]}]}
    ]

    item = %AST.Function{
      name: :example,
      args: [],
      returns: A.type_path(:bool),
      attrs: [%AST.Attribute{path: [:example], args: args}],
      body: [A.return_stmt(true)]
    }

    source = Rust.render(item)
    assert source =~ "tool::flag"
    assert source =~ "tool::name ="
    assert source =~ "tool::nested(inner)"
    assert RustQ.valid?(source, "metadata.rs")
    assert Metadata.normalize(args) == args
  end

  test "normalization preserves repeated keys and nested predicates" do
    assert [
             %Metadata.List{
               parts: [:any],
               items: [
                 %Metadata.NameValue{parts: [:target_os], value: "linux"},
                 %Metadata.NameValue{parts: [:target_os], value: "macos"}
               ]
             }
           ] = Metadata.normalize(any: [target_os: "linux", target_os: "macos"])
  end
end
