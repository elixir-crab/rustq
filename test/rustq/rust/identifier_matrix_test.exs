defmodule RustQ.Rust.IdentifierMatrixTest do
  @moduledoc """
  Renders every AST position that holds a Rust identifier with every Rust keyword, natively
  inside an item and through the text renderer on its own. Each must either render Rust that
  parses or raise a `RustQ.Diagnostic.Error`; a keyword Rust can write raw must render.
  """

  use ExUnit.Case, async: true

  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Schema

  # The Rust reference's strict, reserved, and weak keywords.
  @keywords ~w(as async await break const continue crate dyn else enum extern false fn for if
               impl in let loop match mod move mut pub ref return self Self static struct super
               trait true type unsafe use where while abstract become box do final gen macro
               override priv try typeof unsized virtual yield union macro_rules raw safe)a

  # Keywords with no raw form, valid only where Rust gives them a meaning, such as a path.
  @path_keywords [:self, :Self, :super, :crate]

  @i32 %AST.TypePath{parts: [:i32]}
  @unit %AST.TypeUnit{}
  @zero %AST.Literal{value: 0}
  @x %AST.Var{name: :x}

  # Fields that hold atoms but are not identifiers Rust code names things with.
  @not_identifiers %{
    "AssignOp.op" => "an operator",
    "UnaryOp.op" => "an operator",
    "MacroVar.fragment" => "a macro fragment specifier, one of a fixed set",
    "PatLiteral.value" => "a literal value",
    "MacroItemCall.args" => "tokens the called macro interprets",
    "Derive.paths" => "rendered as Struct.derive and Enum.derive are",
    "Impl.lifetimes" => "a lifetime; Rust has no raw form of a keyword lifetime",
    "Function.lifetimes" => "a lifetime; Rust has no raw form of a keyword lifetime",
    "Struct.lifetimes" => "a lifetime; Rust has no raw form of a keyword lifetime",
    "TypePath.lifetimes" => "a lifetime; Rust has no raw form of a keyword lifetime",
    "TypeRef.lifetime" => "a lifetime; Rust has no raw form of a keyword lifetime",
    "TypeBareFn.lifetimes" => "a lifetime; Rust has no raw form of a keyword lifetime",
    "TypeImplTrait.lifetime" => "a lifetime; Rust has no raw form of a keyword lifetime"
  }

  defp function(body), do: %AST.Function{name: :f, returns: @unit, body: body}

  # Positions rendered natively, as part of an item.
  defp item_positions do
    [
      {"Function.name", &%AST.Function{name: &1, returns: @unit}},
      {"FunctionArg.name",
       &%AST.Function{name: :f, returns: @unit, args: [%AST.FunctionArg{name: &1, type: @i32}]}},
      {"Struct.name", &%AST.Struct{name: &1}},
      {"StructField.name",
       &%AST.Struct{name: :S, fields: [%AST.StructField{name: &1, type: @i32}]}},
      {"Struct.derive", &%AST.Struct{name: :S, derive: [[:a, &1]]}},
      {"Enum.name", &%AST.Enum{name: &1, variants: [%AST.EnumVariant{name: :A}]}},
      {"Enum.derive",
       &%AST.Enum{name: :E, derive: [[:a, &1]], variants: [%AST.EnumVariant{name: :A}]}},
      {"EnumVariant.name", &%AST.Enum{name: :E, variants: [%AST.EnumVariant{name: &1}]}},
      {"Const.name", &%AST.Const{name: &1, type: @i32, expr: @zero}},
      {"Static.name", &%AST.Static{name: &1, type: @i32, expr: @zero}},
      {"TypeAlias.name", &%AST.TypeAlias{name: &1, type: @i32}},
      {"Module.name", &%AST.Module{name: &1}},
      {"Use.parts", &%AST.Use{parts: [:a, &1]}},
      {"Use.group", &%AST.Use{group: {[:a, &1], [:b, &1]}}},
      {"Attribute.path",
       &%AST.Function{name: :f, returns: @unit, attrs: [%AST.Attribute{path: [:a, &1]}]}},
      {"Attribute.args",
       &%AST.Function{
         name: :f,
         returns: @unit,
         attrs: [%AST.Attribute{path: [:allow], args: [&1]}]
       }},
      {"TypePath.parts", &%AST.Function{name: :f, returns: %AST.TypePath{parts: [:a, &1]}}},
      {"MacroRules.name",
       &%AST.MacroRules{name: &1, rules: [%AST.MacroRule{pattern: [], expansion: []}]}},
      {"MacroVar.name",
       &%AST.MacroRules{
         name: :m,
         rules: [
           %AST.MacroRule{
             pattern: [%AST.MacroVar{name: &1, fragment: :expr}],
             expansion: [%AST.MacroCapture{name: &1}]
           }
         ]
       }},
      {"MacroCapture.name",
       &%AST.MacroRules{
         name: :m,
         rules: [
           %AST.MacroRule{
             pattern: [%AST.MacroVar{name: &1, fragment: :expr}],
             expansion: [%AST.MacroCapture{name: &1}]
           }
         ]
       }},
      {"Var.name", &function([%AST.Return{expr: %AST.Var{name: &1}}])},
      {"PatVar.name", &function([%AST.Let{pattern: %AST.PatVar{name: &1}, expr: @zero}])},
      {"LocalCall.name", &function([%AST.ExprStmt{expr: %AST.LocalCall{name: &1}}])},
      {"MethodCall.method",
       &function([%AST.ExprStmt{expr: %AST.MethodCall{receiver: @x, method: &1}}])},
      {"Field.field", &function([%AST.Return{expr: %AST.Field{receiver: @x, field: &1}}])},
      {"StructLiteral.fields",
       &function([
         %AST.Return{
           expr: %AST.StructLiteral{path: %AST.Path{parts: [:S]}, fields: [{&1, @zero}]}
         }
       ])},
      {"PatStruct.fields",
       &function([
         %AST.Let{
           pattern: %AST.PatStruct{
             path: %AST.Path{parts: [:S]},
             fields: [{&1, %AST.PatVar{name: :y}}]
           },
           expr: @x
         }
       ])},
      {"Path.parts", &function([%AST.Return{expr: %AST.Path{parts: [:a, &1]}}])},
      {"Closure.args", &function([%AST.Return{expr: %AST.Closure{args: [&1], body: @zero}}])},
      {"AtomValue.name", &function([%AST.Return{expr: %AST.AtomValue{name: &1}}])},
      {"AtomValue.module",
       &function([%AST.Return{expr: %AST.AtomValue{name: :a, module: [:atoms, &1]}}])},
      {"NifRaiseAtom.name", &function([%AST.Return{expr: %AST.NifRaiseAtom{name: &1}}])}
    ]
  end

  # Positions the text renderer writes when a node is rendered on its own.
  defp text_positions do
    [
      {"Var.name", :expr, &%AST.Var{name: &1}},
      {"Field.field", :expr, &%AST.Field{receiver: @x, field: &1}},
      {"MethodCall.method", :expr, &%AST.MethodCall{receiver: @x, method: &1}},
      {"Path.parts", :expr, &%AST.Path{parts: [:a, &1]}},
      {"Closure.args", :expr, &%AST.Closure{args: [&1], body: @zero}},
      {"AtomValue.name", :expr, &%AST.AtomValue{name: &1}},
      {"AtomValue.module", :expr, &%AST.AtomValue{name: :a, module: [:atoms, &1]}},
      {"PatVar.name", :pattern, &%AST.PatVar{name: &1}},
      {"PatAtomGuard.name", :pattern, &%AST.PatAtomGuard{name: &1}},
      {"PatAtomGuard.module", :pattern, &%AST.PatAtomGuard{name: :a, module: [:atoms, &1]}}
    ]
  end

  test "every keyword renders as valid Rust or a diagnostic in every item position" do
    failures =
      for {label, build} <- item_positions(),
          keyword <- @keywords,
          failure = check(label, keyword, fn -> Rust.render(build.(keyword)) end),
          do: failure

    assert failures == []
  end

  test "every keyword renders as valid Rust or a diagnostic through the text renderer" do
    failures =
      for {label, kind, build} <- text_positions(),
          keyword <- @keywords,
          failure = check(label, keyword, fn -> wrap(kind, Rust.render(build.(keyword))) end),
          do: failure

    assert failures == []
  end

  test "covers every AST field that names a Rust identifier" do
    covered =
      MapSet.new(
        Enum.map(item_positions(), &elem(&1, 0)) ++ Enum.map(text_positions(), &elem(&1, 0))
      )

    uncovered =
      for node <- Schema.nodes(),
          {field, type} <- node.fields,
          identifier_field?(type),
          label = "#{node.module |> Module.split() |> List.last()}.#{field}",
          label not in covered and not Map.has_key?(@not_identifiers, label),
          do: label

    assert uncovered == []
  end

  defp check(label, keyword, render) do
    case render_result(render) do
      {:ok, source} ->
        if RustQ.valid?(source, "identifier_matrix.rs"),
          do: nil,
          else: {label, keyword, :invalid_rust, source}

      {:diagnostic, _message} when keyword in @path_keywords ->
        nil

      {:diagnostic, message} ->
        {label, keyword, :rejected, message}

      {:crash, error} ->
        {label, keyword, :crashed, error}
    end
  end

  defp render_result(render) do
    {:ok, IO.iodata_to_binary(render.())}
  rescue
    error in RustQ.Diagnostic.Error -> {:diagnostic, Exception.message(error)}
    error -> {:crash, Exception.format(:error, error)}
  end

  defp wrap(:expr, source), do: "fn matrix(x: S) { let _ = #{source}; }"
  defp wrap(:pattern, source), do: "fn matrix(value: i32) { match value { #{source} => {} } }"

  defp identifier_field?({:type, _, :atom, []}), do: true
  defp identifier_field?({:type, _, :list, [inner]}), do: identifier_field?(inner)
  defp identifier_field?({:type, _, :tuple, [first | _rest]}), do: identifier_field?(first)

  defp identifier_field?({:type, _, :union, members}),
    do: Enum.any?(members, &(identifier_field?(&1) and not match?({:atom, _, _}, &1)))

  defp identifier_field?(_type), do: false
end
