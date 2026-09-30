defmodule RustQ.Rust.AST.BuilderTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust

  alias RustQ.Rust.AST.{
    Arm,
    Err,
    Function,
    Let,
    Match,
    Path,
    PatVar,
    PatWildcard,
    Return,
    TypePath
  }

  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.TypeBuilder, as: T

  require A

  test "builds ergonomic function argument and Rustler type nodes" do
    function = %Function{
      name: :typed,
      lifetimes: [:a],
      args: [
        A.arg(:canvas, T.ref([:skia_safe, :Canvas])),
        A.arg(:term, T.term()),
        A.arg(:opts, T.path([:generated_opts, :TranslateOpts], lifetimes: [:a])),
        A.arg(:raw_opts, "&[(Atom, Term<'a>)]")
      ],
      returns: T.nif_result(T.unit()),
      body: [A.return(A.ok())]
    }

    source = render_function(function)

    assert source =~ "fn typed<'a>("
    assert source =~ "canvas: &skia_safe::Canvas"
    assert source =~ "term: Term<'a>"
    assert source =~ "opts: generated_opts::TranslateOpts<'a>"
    assert source =~ "raw_opts: &[(Atom, Term<'a>)]"
    assert source =~ "-> NifResult<()>"
  end

  test "builds exclusive and inclusive range expressions" do
    assert Rust.render(A.range(0, 10)) == "0..10"
    assert Rust.render(A.range(0, 10, inclusive: true)) == "0..=10"
  end

  test "builds slice and array type nodes" do
    assert render_type(T.slice(T.ref(:str))) == "[&str]"
    assert render_type(T.ref(T.slice(T.ref(:str)))) == "&[&str]"
    assert render_type(T.array(:u8, 4)) == "[u8; 4]"
  end

  test "builds qualified bare function type nodes" do
    type =
      T.bare_fn([T.ref(:u8, lifetime: :a)],
        returns: :bool,
        lifetimes: [:a],
        unsafe: true,
        external: true,
        abi: "C",
        variadic: true
      )

    assert Rust.render_type(type) == ~s|for<'a> unsafe extern "C" fn(&'a u8, ...) -> bool|
  end

  test "builds structural impl Trait types" do
    assert Rust.render_type(T.impl_trait(["Into<u32>", "Send"])) == "impl Into<u32> + Send"
  end

  test "splits Rust path strings into type and expression path parts" do
    assert %TypePath{parts: ["paint", "Cap"]} = T.path("paint::Cap")
    assert Rust.render_type(T.path("paint::Cap")) == "paint::Cap"

    assert %Path{parts: ["paint", "Cap", "Butt"]} = A.path("paint::Cap::Butt")
    assert Rust.render(A.path("paint::Cap::Butt")) == "paint::Cap::Butt"
  end

  test "renders Rust keywords in paths as raw identifiers" do
    assert Rust.render(A.path([:atoms, :type])) == "atoms::r#type"
  end

  test "renders Rust keywords in fields, named fields, and macro items as raw identifiers" do
    code =
      RustQ.render!("__rq_items!();", "keyword_fields.rs",
        splice: [
          items: [
            A.macro_item_call([:rustler, :atoms], [{:type, "type"}, :value]),
            %Function{
              name: :keyword_fields,
              args: [A.arg(:node, A.type_path(:Node))],
              returns: A.type_path(:Node),
              body: [
                A.let(:kind, A.field(:node, :type)),
                A.return(
                  A.match_expr(:node, [
                    %Arm{
                      pattern: P.struct([:Node], type: P.var(:kind)),
                      body: [A.return(A.struct_expr(A.path([:Node]), type: :kind))]
                    }
                  ])
                )
              ]
            }
          ]
        ]
      )

    assert code =~ ~S|r#type = "type"|
    assert code =~ "let kind = node.r#type;"
    assert code =~ "Node { r#type: kind }"
  end

  test "renders token macro expressions through native AST" do
    function = %Function{
      name: :pat_none,
      args: [],
      returns: "NifResult<Pat>",
      body:
        A.block do
          A.return(A.call(:parse_pat, [A.token_macro(:quote, "None")]))
        end
    }

    assert render_function(function) =~ "parse_pat(quote!(None))"
  end

  test "renders structural item macros with repeated token trees" do
    alias RustQ.Rust.AST.Builder, as: A

    macro =
      A.macro_rules(
        :kiwi_sparse_message_descriptor_decoder,
        A.macro_rule(
          [
            "fn ",
            A.macro_var(:name, :ident),
            "; fields [",
            A.macro_repeat([
              A.macro_var(:field_id, :literal),
              " => ",
              A.macro_var(:field_name, :literal),
              ": ",
              A.macro_var(:field_mode, :ident),
              " ",
              A.macro_var(:field_decode, :ident),
              ";"
            ]),
            "]"
          ],
          [
            "fn ",
            A.macro_capture(:name),
            "() { let _fields = &[",
            A.macro_repeat([
              "KiwiSparseField { id: ",
              A.macro_capture(:field_id),
              ", name: ",
              A.macro_capture(:field_name),
              ", repeated: kiwi_sparse_repeated!(",
              A.macro_capture(:field_mode),
              "), decode: ",
              A.macro_capture(:field_decode),
              " },"
            ]),
            "]; }"
          ]
        ),
        attrs: [A.allow_attr(:unused_macros)]
      )

    source = Rust.render(macro)

    assert source =~ "macro_rules! kiwi_sparse_message_descriptor_decoder"

    assert source =~
             "$($field_id:literal => $field_name:literal: $field_mode:ident $field_decode:ident;)*"

    assert source =~ "$(KiwiSparseField { id: $field_id, name: $field_name"
    assert RustQ.valid?(source, "structural_item_macro.rs")
  end

  test "renders function receiver arguments" do
    function = %Function{
      name: :encode,
      lifetimes: [:a],
      args: [A.receiver(), A.arg(:env, A.type_path([:rustler, :Env], lifetimes: [:a]))],
      returns: A.type_path([:rustler, :Term], lifetimes: [:a]),
      body: [A.return(A.var(:term))]
    }

    assert render_function(function) =~
             "fn encode<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a>"
  end

  test "renders lifetime-bearing impl blocks" do
    impl =
      A.impl(A.type_path(:Content),
        trait: A.type_path([:rustler, :Decoder], lifetimes: [:a]),
        lifetimes: [:a],
        items: [
          %Function{
            name: :decode,
            args: [A.arg(:term, A.type_path(:Term, lifetimes: [:a]))],
            returns: A.type_path(:Self),
            body: [A.return(A.var(:todo))]
          }
        ]
      )

    assert Rust.render(impl) =~
             "impl<'a> rustler::Decoder<'a> for Content"
  end

  test "renders item-level Rust AST nodes through native AST" do
    source =
      Rust.render_all([
        A.use([:quote, :quote]),
        A.use({[:rustler], [:Atom, :Env]}),
        A.module(
          :generated,
          [
            A.const(:NAME, "&str", "Elixir.Example", vis: :crate),
            A.macro_item("rustler::atoms! { ok }")
          ],
          vis: :crate
        )
      ])

    assert source =~ "use quote::quote;"
    assert source =~ "use rustler::{Atom, Env};"
    assert source =~ "pub(crate) mod generated"
    assert source =~ ~s|pub(crate) const NAME: &str = "Elixir.Example";|
    assert source =~ "rustler::atoms!"
  end

  test "builds tuple expressions" do
    function = %Function{
      name: :pair,
      args: [],
      returns: "(i32, i32)",
      body: [A.return(A.tuple([1, 2]))]
    }

    assert render_function(function) =~ "(1, 2)"
  end

  test "renders numeric literal match patterns" do
    function = %Function{
      name: :compact,
      args: [A.arg(:id, :i64)],
      returns: "NifResult<Atom>",
      body: [
        A.return_stmt(
          A.match_expr(A.var(:id), [
            %Arm{pattern: P.lit(1), body: [A.return_stmt(A.ok(A.atom(:clear)))]},
            A.badarg_arm()
          ])
        )
      ]
    }

    source = render_function(function)

    assert source =~ "1 =>"
    assert source =~ "Ok(atoms::clear())"
  end

  test "renders loop and break statements" do
    function = %Function{
      name: :read_until_done,
      args: [],
      returns: "NifResult<()> ",
      body:
        A.block do
          A.loop([
            A.stmt(A.call(:step)),
            A.continue(),
            A.break()
          ])

          A.return(A.ok())
        end
    }

    source = render_function(function)

    assert source =~ "loop {"
    assert source =~ "step();"
    assert source =~ "continue;"
    assert source =~ "break;"
  end

  test "renders match arm guards" do
    function = %Function{
      name: :guarded,
      args: [A.arg(:value, :i64)],
      returns: "NifResult<i64>",
      body:
        A.block do
          A.return do
            A.match A.var(:value) do
              A.arm P.var(:value), when: A.gt(:value, 0) do
                A.return(A.ok(:value))
              end

              A.badarg_arm()
            end
          end
        end
    }

    source = render_function(function)

    assert source =~ "value if value > 0 =>"
    assert source =~ "Ok(value)"
  end

  test "builds semantic badarg helpers" do
    assert %Path{parts: [:rustler, :Error, :BadArg]} = A.badarg()

    assert %Return{expr: %Err{expr: %Path{parts: [:rustler, :Error, :BadArg]}}} =
             A.return_badarg()

    assert %Arm{pattern: %PatWildcard{}, body: [%Return{}]} = A.badarg_arm()
  end

  test "renders if and binary operators through native AST" do
    function = %Function{
      name: :expect,
      args: [left: "bool", right: "bool"],
      returns: "NifResult<()>",
      body:
        A.block do
          A.return(
            A.if_expr(
              A.and_(A.var(:left), A.eq(A.var(:right), true)),
              [A.return(A.ok())],
              [A.return_badarg()]
            )
          )
        end
    }

    source = render_function(function)

    assert source =~ "if left && right == true"
    assert source =~ "Ok(())"
    assert source =~ "Err(rustler::Error::BadArg)"
  end

  test "builds structured blocks with do-end match arms" do
    body =
      A.block do
        A.let(
          :struct_name,
          A.try(
            A.method(
              A.try(A.method(:term, :map_get, [A.path_call([:atoms, :__struct__])])),
              :atom_to_string
            )
          )
        )

        A.return do
          A.match A.method(:struct_name, :as_str) do
            A.arm P.lit("Elixir.Click") do
              A.return(A.method(A.call(:decode_click, [:term]), :map, [A.path([:Event, :Click])]))
            end

            A.badarg_arm()
          end
        end
      end

    assert [
             %Let{pattern: %PatVar{name: :struct_name}},
             %Return{expr: %Match{arms: [%Arm{}, %Arm{}]}}
           ] = body
  end

  defp render_function(%Function{} = function) do
    function
    |> Map.update!(:args, &A.function_args/1)
    |> Map.update!(:returns, &A.type/1)
    |> Rust.render()
  end

  defp render_type(type), do: Rust.render_type(type)
end
