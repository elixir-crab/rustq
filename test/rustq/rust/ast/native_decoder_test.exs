defmodule RustQ.Rust.AST.NativeDecoderTest do
  use ExUnit.Case, async: true

  alias RustQ.Diagnostic
  alias RustQ.Native.Nif, as: Native
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.Function
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.Render
  alias RustQ.Rust.AST.TypePath

  require A

  test "native AST rendering failures raise structured diagnostics" do
    invalid = %Function{name: :bad, args: [], returns: %TypePath{parts: []}, body: []}

    error = assert_raise Diagnostic.Error, fn -> Render.render_function(invalid) end
    diagnostic = error.diagnostic

    assert diagnostic.phase == :render
    assert diagnostic.kind == :native_render_failed
    assert diagnostic.details.ast_module == Function
    assert %ArgumentError{} = diagnostic.details.cause
    assert diagnostic.message =~ "native AST rendering failed"
    assert diagnostic.snippet =~ "%RustQ.Rust.AST.Function"
  end

  test "method receiver borrows and unary operators preserve precedence" do
    receiver = A.var(:value)

    for {expression, expected} <- [
          {A.ref(receiver), "(&value).len()"},
          {%AST.Ref{expr: receiver, mutable: true}, "(&mut value).len()"},
          {%AST.UnaryOp{op: :deref, expr: receiver}, "(*value).len()"}
        ] do
      expression = A.method(expression, :len)
      assert expression |> Render.render_expr() |> IO.iodata_to_binary() == expected

      source =
        render_ast(%Function{
          name: :probe,
          returns: A.type_path(:usize),
          body: [%AST.Return{expr: expression}]
        })

      assert source =~ expected
    end
  end

  test "native type decoding accepts only structural type nodes" do
    assert_raise ArgumentError, fn ->
      Native.render_ast(%Function{name: :legacy, args: [], returns: "i32", body: []})
    end
  end

  test "native decoder renders macro item calls with literal arguments" do
    source =
      render_ast(A.macro_item_call([:rustler, :init], literal: "Elixir.RustQ.Native"))

    assert source =~ "rustler::init!"
    assert source =~ ~s|"Elixir.RustQ.Native"|
  end

  test "Elixir renderer renders macro repeat expressions structurally" do
    source =
      %AST.MacroRepeatExpr{expr: A.var(:value), separator: ",", operator: "*"}
      |> Render.render_expr()
      |> IO.iodata_to_binary()

    assert source == "$(value,)*"
  end

  test "native decoder renders token-shaped macro item calls" do
    source =
      render_ast(
        A.macro_item_token_call(:fig_scene_skip_field_decoder, [
          "fn ",
          A.path(:skip_fig_message_field),
          "; decoder ",
          A.path(:decoder),
          "; field ",
          A.path(:field),
          "; definition ",
          A.lit("scene summary"),
          "; skip_fields [",
          A.lit(1),
          " => ",
          A.lit(false),
          " ",
          A.lit(true),
          " ",
          A.path(:skip_blob_from_decoder),
          ";]"
        ])
      )

    assert source =~ "fig_scene_skip_field_decoder!"
    assert source =~ "fn skip_fig_message_field"
    assert source =~ ~s|definition "scene summary"|
    assert source =~ "1 => false true skip_blob_from_decoder"
  end

  test "dogfooded item and type decoders render use, module, macro, constants, structs, and enums" do
    use_source = render_ast(%AST.Use{tree: "std::fmt"})

    module_source =
      render_ast(%AST.Module{
        name: :generated,
        vis: :crate,
        items: [%AST.Const{name: :ANSWER, type: A.type_path(:u32), expr: A.lit(42)}]
      })

    macro_source = render_ast(%AST.MacroItem{source: "type Alias = u32;"})

    const_source =
      render_ast(%AST.Const{
        name: :LIMIT,
        type: %AST.TypeOption{inner: %AST.TypeRef{inner: A.type_path(:str), lifetime: :a}},
        expr: A.none(),
        vis: :crate
      })

    struct_source =
      render_ast(%AST.Struct{
        name: :Holder,
        lifetimes: [:a, :b],
        vis: :pub,
        fields: [
          %AST.StructField{
            name: :value,
            type: %AST.TypeRef{inner: A.type_path(:str), lifetime: :a},
            vis: :pub
          }
        ]
      })

    enum_source =
      render_ast(%AST.Enum{
        name: :Maybe,
        vis: :pub,
        variants: [
          %AST.EnumVariant{name: :None},
          %AST.EnumVariant{name: :Some, tuple: [%AST.TypeVec{inner: A.type_path(:u8)}]}
        ]
      })

    assert use_source =~ "use std::fmt;"
    assert module_source =~ "pub(crate) mod generated"
    assert module_source =~ "const ANSWER: u32 = 42;"
    assert macro_source =~ "type Alias = u32;"
    assert const_source =~ "pub(crate) const LIMIT: Option<&'a str> = None;"
    assert struct_source =~ "pub struct Holder<'a, 'b>"
    assert struct_source =~ "pub value: &'a str"
    assert enum_source =~ "pub enum Maybe"
    assert enum_source =~ "Some(Vec<u8>)"
  end

  test "generated statement decoders render expression and return statements" do
    source =
      render_ast(%AST.Function{
        name: :statements,
        args: [],
        returns: "i32",
        body:
          A.block do
            A.stmt(A.call(:side_effect))
            A.return(A.var(:value))
          end
      })

    assert source =~ "side_effect();"
    assert source =~ "value"
  end

  test "generated expression decoders render field, calls, methods, and refs" do
    source =
      render_ast(%AST.Function{
        name: :exprs,
        args: [],
        returns: "NifResult<()> ",
        body:
          A.block do
            A.stmt(%AST.Field{receiver: A.var(:opts), field: :fill})
            A.stmt(A.path_call([:Rect, :from_xywh], [:x, :y, :width, :height]))
            A.stmt(A.method(:canvas, :draw_rect, [A.ref(:rect), A.mut_ref(:paint)]))

            A.stmt(
              A.method(%AST.Cast{expr: A.var(:value), type: A.type_path(:f32)}, :to_ne_bytes)
            )

            A.return(A.ok())
          end
      })

    assert source =~ "opts.fill;"
    assert source =~ "Rect::from_xywh(x, y, width, height);"
    assert source =~ "canvas.draw_rect(&rect, &mut paint);"
    assert source =~ "(value as f32).to_ne_bytes();"
  end

  test "native decoder renders mutable and typed let statements" do
    mutable_source =
      render_ast(%AST.Function{
        name: :mutable_let,
        args: [],
        returns: "String",
        body:
          A.block do
            A.let_mut(:tokens, A.call(:read_tokens))
            A.return(:tokens)
          end
      })

    assert mutable_source =~ "let mut tokens = read_tokens();"

    source =
      render_ast(%AST.Function{
        name: :typed_let,
        args: [],
        returns: "String",
        body:
          A.block do
            A.let(:tokens, A.call(:read_tokens), type: "String")
            A.return(:tokens)
          end
      })

    assert source =~ "let tokens: String = read_tokens();"
  end

  test "generated expression decoders render local calls, struct literals, and ok expressions" do
    source =
      render_ast(%AST.Function{
        name: :more_exprs,
        args: [],
        returns: "NifResult<Rect>",
        body:
          A.block do
            A.stmt(A.call(:todo!, []))

            A.return(
              A.ok(
                A.struct_expr([:Rect],
                  x: A.var(:x),
                  y: A.var(:y)
                )
              )
            )
          end
      })

    assert source =~ "todo!();"
    assert source =~ "Ok(Rect { x, y })"
  end

  test "generated expression decoders render literal, token macro, and binary expressions" do
    literal_source =
      render_ast(%AST.Function{
        name: :literal_expr,
        args: [],
        returns: "&'static str",
        body: A.block(do: A.return(A.lit("hello")))
      })

    float_source =
      render_ast(%AST.Function{
        name: :float_expr,
        args: [],
        returns: "f32",
        body: A.block(do: A.return(A.lit(1.0)))
      })

    token_macro_source =
      render_ast(%AST.Function{
        name: :token_macro_expr,
        args: [],
        returns: "TokenStream",
        body: A.block(do: A.return(A.token_macro(:quote, "None")))
      })

    binary_source =
      render_ast(%AST.Function{
        name: :binary_expr,
        args: [],
        returns: "bool",
        body: A.block(do: A.return(A.and_(A.eq(:left, :right), :ok)))
      })

    deref_source =
      render_ast(%AST.Function{
        name: :deref_expr,
        args: [value: "&i64"],
        returns: "i64",
        body: A.block(do: A.return(A.deref(:value)))
      })

    assert literal_source =~ ~s|"hello"|
    assert float_source =~ "1.0"
    refute float_source =~ "1f64"
    assert token_macro_source =~ "quote!(None)"
    assert binary_source =~ "left == right && ok"
    assert deref_source =~ "*value"
  end

  test "generated arm decoder renders atom guard patterns" do
    source =
      render_ast(%AST.Function{
        name: :atom_guard,
        args: [value: "Atom"],
        returns: "i32",
        body:
          A.block do
            A.return do
              A.match A.var(:value) do
                A.arm %AST.PatAtomGuard{name: :ok} do
                  A.return(1)
                end

                A.arm A.wildcard() do
                  A.return(0)
                end
              end
            end
          end
      })

    assert source =~ "value if value == atoms::ok() =>"
  end

  test "generated pattern decoders render tuple, path tuple, and struct patterns" do
    source =
      render_ast(%AST.Function{
        name: :pattern_exprs,
        args: [],
        returns: "i32",
        body:
          A.block do
            A.return do
              A.match A.var(:event) do
                A.arm %AST.PatTuple{patterns: [A.pat(:left), A.pat(:right)]} do
                  A.return(:left)
                end

                A.arm P.path_tuple([:Event, :Click], [P.var(:click)]) do
                  A.return(:click)
                end

                A.arm P.struct([:Click], name: P.var(:name)) do
                  A.return(:name)
                end
              end
            end
          end
      })

    assert source =~ "(left, right) =>"
    assert source =~ "Event::Click(click) =>"
    assert source =~ "Click { name } =>"
  end

  test "generated expression decoders render match, if, and raise atom expressions" do
    match_source =
      render_ast(%AST.Function{
        name: :match_expr,
        args: [],
        returns: "NifResult<()> ",
        body:
          A.block do
            A.return do
              A.match A.var(:value) do
                A.arm P.ok(:inner) do
                  A.return(A.ok(:inner))
                end

                A.arm P.err(:reason) do
                  A.return(A.err(:reason))
                end
              end
            end
          end
      })

    if_source =
      render_ast(%AST.Function{
        name: :if_expr,
        args: [],
        returns: "NifResult<()> ",
        body:
          A.block do
            A.return(
              A.if_expr(
                :condition,
                [A.return(A.ok())],
                [A.return_badarg()]
              )
            )
          end
      })

    raise_source =
      render_ast(%AST.Function{
        name: :raise_expr,
        args: [],
        returns: "NifResult<()> ",
        body: A.block(do: A.return(%AST.NifRaiseAtom{name: :invalid}))
      })

    assert match_source =~ "match value"
    assert match_source =~ "Ok(inner)"
    assert if_source =~ "if condition"
    assert if_source =~ "Err(rustler::Error::BadArg)"
    assert raise_source =~ ~s|rustler::Error::RaiseAtom("invalid")|
  end

  test "generated expression decoders render try, tuple, some, and err expressions" do
    try_source =
      render_ast(%AST.Function{
        name: :try_expr,
        args: [],
        returns: "NifResult<()> ",
        body: A.block(do: A.return(A.try(A.call(:fallible))))
      })

    tuple_source =
      render_ast(%AST.Function{
        name: :tuple_expr,
        args: [],
        returns: "(i32, i32)",
        body: A.block(do: A.return(%AST.Tuple{values: [A.var(:left), A.var(:right)]}))
      })

    some_source =
      render_ast(%AST.Function{
        name: :some_expr,
        args: [],
        returns: "Option<i32>",
        body: A.block(do: A.return(A.some(:value)))
      })

    err_source =
      render_ast(%AST.Function{
        name: :err_expr,
        args: [],
        returns: "NifResult<()> ",
        body: A.block(do: A.return(A.err(A.badarg())))
      })

    assert try_source =~ "fallible()?"
    assert tuple_source =~ "(left, right)"
    assert some_source =~ "Some(value)"
    assert err_source =~ "Err(rustler::Error::BadArg)"
  end

  defp render_ast(%AST.Function{} = function) do
    function
    |> Map.update!(:args, &A.function_args/1)
    |> Map.update!(:returns, &A.type/1)
    |> Native.render_ast()
  end

  defp render_ast(ast), do: Native.render_ast(ast)
end

defmodule RustQ.Rust.AST.NativeDecoderBehaviorTest do
  use ExUnit.Case,
    async: true,
    parameterize:
      Enum.map(RustQ.ASTSamples.all(), fn {name, ast} ->
        %{sample_name: name, sample_ast: ast}
      end)

  alias RustQ.Native.Nif, as: Native
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A

  test "renders every schema node behaviorally", %{sample_name: name, sample_ast: ast} do
    source = render_ast(ast)

    assert is_binary(source)

    assert RustQ.ASTSamples.validate_rendered?(name, ast, source),
           "sample for #{name} should render expected behavior, got:\n#{source}"
  end

  defp render_ast(%AST.Function{} = function) do
    function
    |> Map.update!(:args, &A.function_args/1)
    |> Map.update!(:returns, &A.type/1)
    |> Native.render_ast()
  end

  defp render_ast(ast), do: Native.render_ast(ast)
end
