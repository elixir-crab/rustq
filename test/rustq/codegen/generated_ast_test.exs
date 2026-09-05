defmodule RustQ.Codegen.GeneratedASTTest do
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
end

defmodule RustQ.Codegen.DispatchCoverageTest do
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

defmodule RustQ.Codegen.TypeContainerDecoderTest do
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

defmodule RustQ.Codegen.DecoderCoverageTest do
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
