defmodule RustQ.Meta.Lower.ContractTest do
  use ExUnit.Case, async: true

  alias RustQ.Diagnostic
  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Meta.AttrCase
  alias RustQ.Meta.GeneratedCase, as: Generated
  alias RustQ.Meta.Lower
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.{Attribute, Function, FunctionArg}

  test "defrust consumes idiomatic Rust-facing attributes" do
    assert %Function{attrs: attrs} =
             MetaAST.functions(AttrCase)
             |> Enum.find(&(&1.name == :render))

    assert [
             %Attribute{path: [:rustler, :nif], args: [schedule: "DirtyCpu"]},
             %Attribute{path: [:allow], args: [:dead_code]},
             %Attribute{
               path: [:allow],
               args: [%RustQ.Rust.AST.Path{parts: [:clippy, :redundant_field_names]}]
             }
           ] = attrs

    source = AttrCase.__rustq_source__()
    assert source =~ ~s|#[rustler::nif(schedule = "DirtyCpu")]|
    assert source =~ "#[allow(dead_code)]"
    assert source =~ "#[allow(clippy::redundant_field_names)]"
  end

  test "generated ASTs are retained before fragment validation" do
    [draw_save, decode_mode, draw_rect, maybe_save | _] = MetaAST.functions(Generated)

    assert %Function{
             name: :draw_save,
             args: [%FunctionArg{name: :canvas, type: %RustQ.Rust.AST.TypeRef{}}]
           } = draw_save

    assert %RustQ.Rust.AST.Return{expr: %RustQ.Rust.AST.Match{}} = hd(decode_mode.body)

    assert %Function{
             args: [
               _canvas_arg,
               %FunctionArg{name: :opts, type: %RustQ.Rust.AST.TypePath{}},
               _raw_opts_arg
             ]
           } = draw_rect

    assert %RustQ.Rust.AST.Let{pattern: %RustQ.Rust.AST.PatVar{name: :rect}} =
             hd(draw_rect.body)

    assert Enum.any?(
             draw_rect.body,
             &match?(
               %RustQ.Rust.AST.Let{
                 pattern: %RustQ.Rust.AST.PatVar{name: :paint},
                 mutable: true
               },
               &1
             )
           )

    assert %RustQ.Rust.AST.ExprStmt{
             expr: %RustQ.Rust.AST.Match{
               arms: [
                 %RustQ.Rust.AST.Arm{pattern: %RustQ.Rust.AST.PatNone{}},
                 %RustQ.Rust.AST.Arm{pattern: %RustQ.Rust.AST.PatSome{}}
               ]
             }
           } = hd(maybe_save.body)
  end

  test "unsupported lowerer patterns raise structured diagnostics" do
    binding_diagnostic =
      try do
        Lower.quoted_body(
          quote do
            %{value: value} = term
            :ok
          end,
          nil
        )

        flunk("expected diagnostic")
      rescue
        error in Diagnostic.Error -> error.diagnostic
      end

    assert binding_diagnostic.phase == :lower
    assert binding_diagnostic.kind == :unsupported_binding_pattern
    assert binding_diagnostic.snippet == "%{value: value}"
    assert binding_diagnostic.message =~ "unsupported defrust binding pattern"
    assert binding_diagnostic.suggestion =~ "variable or tuple pattern"

    match_diagnostic =
      try do
        Lower.quoted_body(
          quote do
            case term do
              %{value: value} -> value
            end
          end,
          nil
        )

        flunk("expected diagnostic")
      rescue
        error in Diagnostic.Error -> error.diagnostic
      end

    assert match_diagnostic.phase == :lower
    assert match_diagnostic.kind == :unsupported_match_pattern
    assert match_diagnostic.snippet == "%{value: value}"
    assert match_diagnostic.message =~ "unsupported defrust match pattern"
  end

  test "non-raw semantic helpers lower directly to AST nodes" do
    assert [
             %AST.Return{
               expr: %AST.Some{expr: %AST.Var{name: :value}}
             }
           ] = Lower.quoted_body(quote(do: expr!(some(value))), nil)

    assert [
             %AST.Return{
               expr: %AST.PatOk{pattern: %AST.PatVar{name: :value}}
             }
           ] = Lower.quoted_body(quote(do: pat!({:ok, value})), nil)

    assert [
             %AST.Return{
               expr: %AST.ExprStmt{expr: %AST.MethodCall{method: :clear}}
             }
           ] = Lower.quoted_body(quote(do: stmt!(canvas.clear(color))), nil)

    assert [
             %AST.Return{
               expr: %AST.Arm{
                 pattern: %AST.PatOk{pattern: %AST.PatVar{name: :value}},
                 body: [%AST.Return{expr: %AST.Var{name: :value}}]
               }
             }
           ] = Lower.quoted_body(quote(do: arm!({:ok, value}, value)), nil)
  end
end
