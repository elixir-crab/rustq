defmodule RustQ.Meta.StdlibTest do
  use ExUnit.Case, async: true

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust.AST

  test "normalizes remote stdlib calls and local Kernel forms" do
    assert {:ok, %Call{module: Enum, function: :count, args: [_values]}} =
             Call.normalize(quote(do: Enum.count(values)))

    assert {:ok, %Call{module: Kernel, function: :byte_size, args: [_value]}} =
             Call.normalize(quote(do: byte_size(value)))

    assert {:ok, piped} =
             Call.pipe_remote(
               quote(do: values),
               quote(do: Enum.map(fn value -> value * 2 end))
             )

    assert {:ok, %Call{module: Enum, function: :map, args: [_values, _mapper]}} =
             Call.normalize(piped)
  end

  test "stdlib modules synthesize collection result types" do
    integer = RustQ.Spec.type(quote(do: integer()))
    values = Type.vec(integer)
    env = Typing.env(vars: %{initial: integer, values: values})

    assert %Type{kind: :i64} = Typing.synth(quote(do: Enum.count(values)), env)

    assert %Type{kind: :option, meta: %{inner: %Type{kind: :i64}}} =
             Typing.synth(quote(do: List.first(values)), env)

    assert %Type{kind: :i64} =
             Typing.synth(
               quote do
                 values
                 |> Enum.map(fn value -> value * value end)
                 |> Enum.reduce(initial, fn value, total -> value + total end)
               end,
               env
             )
  end

  test "lowers Enum reverse through the stdlib dispatcher" do
    integer = RustQ.Spec.type(quote(do: integer()))

    assert [
             %AST.Return{
               expr: %AST.MethodCall{
                 method: :collect,
                 receiver: %AST.MethodCall{
                   method: :rev,
                   receiver: %AST.MethodCall{method: :into_iter}
                 }
               }
             }
           ] =
             Lower.quoted_body(quote(do: Enum.reverse(values)), Type.vec(integer), %{
               values: Type.vec(integer)
             })
  end

  test "rejects integer division spelled as floating-point division" do
    integer = RustQ.Spec.type(quote(do: integer()))
    float = RustQ.Spec.type(quote(do: float()))

    assert_raise Diagnostic.Error, ~r/explicit floating-point conversion/, fn ->
      Lower.quoted_body(quote(do: left / right), float, %{left: integer, right: integer})
    end
  end

  test "constant tuple size preserves evaluation of its argument" do
    integer = RustQ.Spec.type(quote(do: integer()))
    tuple = Type.tuple([integer, integer])

    assert [
             %AST.Return{
               expr: %AST.BlockExpr{
                 body: [
                   %AST.Let{pattern: %AST.PatWildcard{}, expr: %AST.Var{name: :value}},
                   %AST.Return{expr: %AST.Literal{value: 2}}
                 ]
               }
             }
           ] = Lower.quoted_body(quote(do: tuple_size(value)), integer, %{value: tuple})
  end

  test "has_key rejects maps with no known structural type" do
    assert_raise Diagnostic.Error, ~r/typed Map lowering requires/, fn ->
      Lower.quoted_body(quote(do: Map.has_key?(value, :x)), nil)
    end
  end

  test "rejects descending ranges instead of silently changing Elixir semantics" do
    assert_raise Diagnostic.Error, ~r/require ascending integer literal bounds/, fn ->
      Lower.quoted_body(quote(do: 3..1), nil)
    end
  end
end
