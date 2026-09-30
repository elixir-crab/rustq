defmodule RustQ.Rust.AST.PatternBuilderTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.PatternBuilder, as: P

  test "builds common pattern nodes without suffixed helper names" do
    assert %AST.PatVar{name: :value} = P.var(:value)
    assert %AST.PatWildcard{} = P.wildcard()
    assert %AST.PatPath{path: %AST.Path{parts: [:Option, :None]}} = P.path([:Option, :None])
    assert %AST.PatLiteral{value: "ready"} = P.lit("ready")
    assert %AST.PatNone{} = P.none()
    assert %AST.PatSome{pattern: %AST.PatVar{name: :value}} = P.some(:value)
    assert %AST.PatOk{pattern: %AST.PatVar{name: :value}} = P.ok(:value)
    assert %AST.PatErr{pattern: %AST.PatVar{name: :reason}} = P.err(:reason)
  end

  test "builds compound pattern nodes" do
    assert %AST.PatPathTuple{
             path: %AST.Path{parts: [:Event, :Click]},
             patterns: [%AST.PatVar{name: :click}]
           } = P.path_tuple([:Event, :Click], [:click])

    assert %AST.PatStruct{
             path: %AST.Path{parts: [:Click]},
             fields: [name: %AST.PatVar{name: :name}]
           } = P.struct([:Click], name: :name)

    assert %AST.PatTuple{patterns: [%AST.PatVar{name: :key}, %AST.PatWildcard{}]} =
             P.tuple([:key, P.wildcard()])
  end
end
