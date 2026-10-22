defmodule RustQ.CodegenTest do
  use ExUnit.Case, async: true

  alias RustQ.Codegen
  alias RustQ.Codegen.Decoders.Item, as: ItemDecoders
  alias RustQ.Codegen.Decoders.Type, as: TypeDecoders
  alias RustQ.Codegen.Modules
  alias RustQ.Meta.AST, as: MetaAST

  alias RustQ.Rust.AST.{
    Closure,
    ExprStmt,
    Function,
    FunctionArg,
    If,
    Let,
    MacroItemCall,
    MethodCall,
    Module,
    Ok,
    Path,
    PathCall,
    Return,
    Try,
    TypeNifResult,
    TypePath,
    TypeRef,
    Var
  }

  test "fails explicitly when the configured formatter is unavailable" do
    assert_raise RustQ.Error, fn ->
      Codegen.generated_ast_support(rustfmt: "rustq-nonexistent-formatter")
    end
  end

  test "generates parseable AST support" do
    source = Codegen.generated_ast_support()

    assert {:ok, _template} = RustQ.parse(source, "generated_ast.rs")
  end

  test "generated modules are AST-backed" do
    modules = Modules.asts()

    assert %Module{name: :atoms, items: [%MacroItemCall{}], vis: :crate} =
             Enum.find(modules, &match?(%Module{name: :atoms}, &1))

    assert %Module{name: :ast_modules, items: constants, vis: :crate} =
             Enum.find(modules, &match?(%Module{name: :ast_modules}, &1))

    constant_names = constants |> Enum.map(& &1.name) |> MapSet.new()
    assert MapSet.member?(constant_names, :FUNCTION)
    refute MapSet.member?(constant_names, :ARM)
    refute MapSet.member?(constant_names, :ATTRIBUTE)
    refute MapSet.member?(constant_names, :DERIVE)
    refute MapSet.member?(constant_names, :FUNCTION_ARG)
    refute MapSet.member?(constant_names, :STRUCT_FIELD)
    refute MapSet.member?(constant_names, :ENUM_VARIANT)

    assert %Function{
             name: :atom,
             vis: :crate,
             args: [
               %FunctionArg{name: :env, type: %TypePath{parts: [:Env]}},
               %FunctionArg{
                 name: :name,
                 type: %TypeRef{inner: %TypePath{parts: [:str]}}
               }
             ],
             returns: %TypeNifResult{inner: %TypePath{parts: [:Atom]}}
           } = Enum.find(List.flatten(modules), &match?(%Function{name: :atom}, &1))
  end

  test "type ref decoder delegates only the syn ref construction boundary" do
    assert %Function{body: body} =
             TypeDecoders
             |> MetaAST.functions()
             |> Enum.find(&(&1.name == :decode_type_ref))

    assert %Return{
             expr: %PathCall{path: %Path{parts: [:super, :parse_type_ref]}}
           } = List.last(body)
  end

  test "dogfooded type helpers cover path and lifetime list boundaries" do
    type_decoders = MetaAST.functions(TypeDecoders)

    assert %Function{name: :path_parts, body: path_body} =
             Enum.find(type_decoders, &(&1.name == :path_parts))

    assert %Let{
             expr: %Try{
               expr: %PathCall{path: %Path{parts: [:super, :decode_string_list]}}
             }
           } =
             hd(path_body)

    assert %Return{expr: %Ok{expr: %MethodCall{method: :join}}} = List.last(path_body)

    assert %Function{name: :decode_lifetime_list, body: lifetime_body} =
             Enum.find(type_decoders, &(&1.name == :decode_lifetime_list))

    assert [
             %Return{
               expr: %PathCall{path: %Path{parts: [:super, :decode_string_list]}}
             }
           ] =
             lifetime_body
  end

  test "dogfooded derive decoder uses iterator lowering" do
    item_decoders = MetaAST.functions(ItemDecoders)

    assert %Function{name: :decode_derive_path_list, body: body} =
             Enum.find(item_decoders, &(&1.name == :decode_derive_path_list))

    assert %Return{
             expr: %MethodCall{
               method: :collect,
               receiver: %MethodCall{
                 method: :map,
                 args: [%Closure{args: [:derive_path]}]
               }
             }
           } = List.last(body)
  end

  test "dogfooded item decoders expose structural AST boundaries" do
    item_decoders = MetaAST.functions(ItemDecoders)

    assert %Function{name: :decode_ast_function, body: function_body} =
             Enum.find(item_decoders, &(&1.name == :decode_ast_function))

    assert %ExprStmt{expr: %Try{}} = hd(function_body)

    assert %Return{
             expr: %PathCall{path: %Path{parts: [:super, :parse_item_function_args]}}
           } = List.last(function_body)

    assert %Function{name: :decode_function_arg, body: arg_body} =
             Enum.find(item_decoders, &(&1.name == :decode_function_arg))

    assert %ExprStmt{expr: %Try{}} = hd(arg_body)

    assert %Return{
             expr: %If{
               condition: %Var{name: :receiver},
               then: [
                 %Return{
                   expr: %PathCall{path: %Path{parts: [:super, :parse_function_receiver]}}
                 }
               ],
               else: else_body
             }
           } = List.last(arg_body)

    assert %Return{
             expr: %PathCall{path: %Path{parts: [:super, :parse_function_arg]}}
           } = List.last(else_body)
  end

  describe "generated helper modules" do
    alias RustQ.Codegen.DecoderHelpers
    alias RustQ.Codegen.Helpers
    alias RustQ.Codegen.ModuleHelpers
    alias RustQ.Rust.AST
    alias RustQ.Rust.AST.Builder, as: A
    alias RustQ.Rust.AST.Function
    alias RustQ.Rust.AST.Path
    alias RustQ.Rust.AST.PathCall
    alias RustQ.Rust.AST.PatternBuilder, as: P
    alias RustQ.Rust.AST.Return
    alias RustQ.Rust.AST.TypeBuilder, as: T

    test "native defrust modules expose crate-visible ASTs" do
      assert %Function{name: :required_field, vis: :crate} =
               Enum.find(Helpers.asts(), &(&1.name == :required_field))

      assert %Function{name: :atom, vis: :crate} =
               Enum.find(ModuleHelpers.asts(), &(&1.name == :atom))
    end

    test "decoder helper ASTs are crate-visible and delegate required fields" do
      helpers = DecoderHelpers.asts()

      assert %Function{
               name: :required_expr,
               vis: :crate,
               body: [
                 %Return{
                   expr: %PathCall{path: %Path{parts: [:super, :decode_expr]}}
                 }
               ]
             } = Enum.find(helpers, &(&1.name == :required_expr))

      assert %AST.Function{name: :required_path, vis: :crate} =
               Enum.find(helpers, &(&1.name == :required_path))

      assert %AST.Function{name: :required_string_list, vis: :crate} =
               Enum.find(helpers, &(&1.name == :required_string_list))
    end

    test "AST category predicates classify generated AST nodes" do
      assert AST.type_node?(T.unit())
      assert AST.type_node?(T.ref(:Canvas))
      refute AST.type_node?(A.var(:value))

      assert AST.expr_node?(A.var(:value))
      assert AST.expr_node?(A.call(:make_value))
      refute AST.expr_node?(A.pat(:value))

      assert AST.pat_node?(A.pat(:value))
      assert AST.pat_node?(P.some(:value))
      refute AST.pat_node?(T.unit())
    end
  end
end
