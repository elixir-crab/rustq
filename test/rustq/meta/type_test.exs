defmodule RustQ.Meta.TypeTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Some.External
  alias RustQ.Spec
  alias RustQ.Syn.Type, as: SynType

  test "maps fitting built-in Elixir types to Rust/Rustler types" do
    assert RustQ.Spec.type(quote(do: atom())).rust == "Atom"
    assert RustQ.Spec.type(quote(do: term())).rust == "Term<'a>"
    assert RustQ.Spec.type(quote(do: boolean())).rust == "bool"
    assert RustQ.Spec.type(quote(do: integer())).rust == "i64"
    assert RustQ.Spec.type(quote(do: float())).rust == "f64"
    assert RustQ.Spec.type(quote(do: number())).rust == "f64"
    assert RustQ.Spec.type(quote(do: binary())).rust == "Vec<u8>"
    assert RustQ.Spec.type(quote(do: [float()])).rust == "Vec<f64>"
    assert RustQ.Spec.type(quote(do: list(integer()))).rust == "Vec<i64>"
    assert RustQ.Spec.type(quote(do: nonempty_list(boolean()))).rust == "Vec<bool>"
  end

  test "extracts vector elements from Syn-derived type paths" do
    item = %Type{kind: :type, rust: "Item", ast: %RustQ.Rust.AST.TypePath{parts: [:Item]}}

    vector = %Type{
      kind: :type,
      rust: "Vec<Item>",
      ast: %RustQ.Rust.AST.TypePath{parts: [:Vec], generics: [item.ast]}
    }

    assert %Type{rust: "Item"} = Type.vec_inner(vector)
  end

  test "compares equivalent Rust type aliases structurally" do
    internal = %Type{
      kind: :type,
      rust: "Cap",
      ast: %RustQ.Rust.AST.TypePath{parts: [:Cap]},
      meta: %{syn_name: "Cap", equivalent_rust_names: ["PaintCap"]}
    }

    public = %Type{
      kind: :type,
      rust: "PaintCap",
      ast: %RustQ.Rust.AST.TypePath{parts: [:PaintCap]},
      meta: %{syn_name: "PaintCap"}
    }

    assert Type.compatible?(internal, public)
    assert Type.compatible?(public, internal)
  end

  test "compares compatible option wrapper inner paths" do
    qualified = %Type{
      kind: :option,
      rust: "Option<skia_safe::ImageFilter>",
      ast: %RustQ.Rust.AST.TypeOption{
        inner: %RustQ.Rust.AST.TypePath{parts: [:skia_safe, :ImageFilter]}
      }
    }

    unqualified = %Type{
      kind: :option,
      rust: "Option<ImageFilter>",
      ast: %RustQ.Rust.AST.TypeOption{inner: %RustQ.Rust.AST.TypePath{parts: [:ImageFilter]}},
      meta: %{
        inner: %Type{
          kind: :type,
          rust: "ImageFilter",
          ast: %RustQ.Rust.AST.TypePath{parts: [:ImageFilter]},
          meta: %{syn_name: "ImageFilter"}
        }
      }
    }

    assert Type.compatible?(qualified, unqualified)
  end

  test "parses external Rust module types from ordinary remote types" do
    assert RustQ.Spec.type(quote(do: GeneratedOpts.OvalOpts.t(R.lifetime(:a)))).rust ==
             "generated_opts::OvalOpts<'a>"

    assert RustQ.Spec.type(quote(do: R.ref(SkiaSafe.Canvas.t()))).rust ==
             "&skia_safe::Canvas"

    assert RustQ.Spec.type(quote(do: R.slice({R.atom(), R.term()}))).rust ==
             "&[(Atom, Term<'a>)]"
  end

  test "detects lifetimes structurally" do
    assert quote(do: term()) |> Spec.type() |> Type.lifetime?(:a)
    assert quote(do: R.slice({R.atom(), R.term()})) |> Spec.type() |> Type.lifetime?(:a)

    assert quote(do: GeneratedOpts.OvalOpts.t(R.lifetime(:a)))
           |> Spec.type()
           |> Type.lifetime?(:a)

    refute quote(do: R.vec(R.u32())) |> Spec.type() |> Type.lifetime?(:a)
  end

  test "categorizes lowered types semantically" do
    number = RustQ.Spec.type(quote(do: number()))
    integer = RustQ.Spec.type(quote(do: integer()))
    boolean = RustQ.Spec.type(quote(do: boolean()))
    atom = RustQ.Spec.type(quote(do: atom()))
    string = RustQ.Spec.type(quote(do: String.t()))
    tuple = RustQ.Spec.type(quote(do: {number(), integer()}))
    external = RustQ.Spec.type(quote(do: Skia.Path.t()))

    assert Type.category(number) == :number
    assert Type.category(integer) == :integer
    assert Type.category(boolean) == :boolean
    assert Type.category(atom) == :atom
    assert Type.category(string) == :string
    assert {:tuple, [^number, ^integer]} = Type.category(tuple)
    assert Type.category(external) == :type
    assert Type.external?(external, Skia.Path, :t)
    refute Type.external?(external, Skia.Paint, :t)
  end

  test "keeps explicit Rust path marker as a low-level escape hatch" do
    assert RustQ.Spec.type(quote(do: R.path({:generated_opts, :OvalOpts}, R.lifetime(:a)))).rust ==
             "generated_opts::OvalOpts<'a>"

    assert RustQ.Spec.type(quote(do: R.path({:skia_safe, :path_1d_path_effect, :Style}))).rust ==
             "skia_safe::path_1d_path_effect::Style"
  end

  test "resolves alias references regardless of declaration order" do
    # `plugin` and `rule_severity` sort after `lint_input`, and are referenced
    # inside a list and a tuple rather than directly.
    %{aliases: aliases} =
      Spec.declarations(
        quote do
          @type lint_input :: %{
                  required(:plugins) => [plugin()],
                  required(:rules) => [{String.t(), rule_severity()}],
                  required(:access) => global_access()
                }
          @type global_access :: :readonly | :writable
          @type plugin :: :react | :vue
          @type rule_severity :: :allow | :warn | :deny
        end
      )

    assert %Type{kind: :struct, meta: %{fields: fields}} = aliases[{:lint_input, 0}]

    assert [
             {:plugins, %Type{ast: %AST.TypeVec{inner: %AST.TypePath{parts: ["Plugin"]}}},
              :required},
             {:rules,
              %Type{
                ast: %AST.TypeVec{
                  inner: %AST.TypeTuple{items: [_string, %AST.TypePath{parts: ["RuleSeverity"]}]}
                }
              }, :required},
             {:access, %Type{ast: %AST.TypePath{parts: ["GlobalAccess"]}}, :required}
           ] = fields
  end

  test "enriches explicit Rust paths from matching local aliases" do
    %{aliases: aliases} =
      Spec.declarations(
        quote do
          @type kiwi_skip_kind :: R.enum(one: [], repeated: [])
          @type kiwi_skip_field :: %{required(:kind) => kiwi_skip_kind()}
        end
      )

    assert %Type{kind: :struct, meta: %{fields: [{:kind, %Type{kind: :rust_enum}, :required}]}} =
             Spec.type(quote(do: R.path(:KiwiSkipField)), aliases)

    assert %Type{kind: :slice, meta: %{inner: %Type{kind: :struct, meta: %{fields: fields}}}} =
             Spec.type(quote(do: R.slice(R.path(:KiwiSkipField))), aliases)

    assert [{:kind, %Type{kind: :rust_enum}, :required}] = fields
  end

  test "keeps external Elixir origin metadata" do
    assert %Type{
             rust: "skia_safe::Canvas",
             meta: %{elixir_module: SkiaSafe.Canvas, elixir_type: :t, elixir_args: []}
           } = RustQ.Spec.type(quote(do: SkiaSafe.Canvas.t()))

    assert %Type{
             rust: "skia_safe::Canvas::borrowed",
             meta: %{elixir_module: SkiaSafe.Canvas, elixir_type: :borrowed, elixir_args: []}
           } = RustQ.Spec.type(quote(do: SkiaSafe.Canvas.borrowed()))
  end

  test "parses Rust static item metadata" do
    assert [static] =
             "test/fixtures/external_statics.rs"
             |> RustQ.Syn.parse_file!()
             |> RustQ.Syn.statics()

    assert %RustQ.Syn.Static{name: "GUID_ATOM", type: "OnceLock < Atom >", mutable: false} =
             static

    assert %RustQ.Syn.Type.Path{name: "OnceLock"} = static.type_ast
  end

  test "converts Syn type metadata to RustQ meta types" do
    assert %Type{kind: :f32, rust: "f32"} =
             Type.from_syn(%SynType.Path{code: "f32", name: "f32", segments: ["f32"]})

    assert %Type{kind: :type, rust: "skia_safe::Canvas"} =
             Type.from_syn(%SynType.Path{
               code: "skia_safe::Canvas",
               name: "Canvas",
               segments: ["skia_safe", "Canvas"]
             })

    assert %Type{kind: :ref, rust: "&Paint", meta: %{inner: %Type{rust: "Paint"}}} =
             Type.from_syn(%SynType.Ref{
               code: "&Paint",
               inner: %SynType.Path{code: "Paint", name: "Paint", segments: ["Paint"]}
             })

    assert %Type{kind: :mut_ref, rust: "&mut Path"} =
             Type.from_syn(%SynType.Ref{
               code: "&mut Path",
               mutable: true,
               inner: %SynType.Path{code: "Path", name: "Path", segments: ["Path"]}
             })

    assert %Type{
             kind: :mut_ref,
             rust: "&'a mut Path",
             ast: %AST.TypeRef{lifetime: :a, mutable: true}
           } =
             Type.from_syn(%SynType.Ref{
               code: "&'a mut Path",
               lifetime: "'a",
               mutable: true,
               inner: %SynType.Path{code: "Path", name: "Path", segments: ["Path"]}
             })

    assert %Type{kind: :option, rust: "Option<Rect>"} =
             Type.from_syn(%SynType.Option{
               code: "Option<Rect>",
               inner: %SynType.Path{code: "Rect", name: "Rect", segments: ["Rect"]}
             })

    assert %Type{kind: :nif_result, rust: "NifResult<Foo>", meta: %{inner: %Type{rust: "Foo"}}} =
             Type.from_syn(%SynType.Path{
               code: "NifResult<Foo>",
               name: "NifResult",
               segments: ["NifResult"],
               args: [%SynType.Path{code: "Foo", name: "Foo", segments: ["Foo"]}]
             })

    assert %Type{kind: :result, rust: "Result<Image, Error>"} =
             Type.from_syn(%SynType.Result{
               code: "Result<Image, Error>",
               ok: %SynType.Path{code: "Image", name: "Image", segments: ["Image"]},
               error: %SynType.Path{code: "Error", name: "Error", segments: ["Error"]}
             })

    result_ast = quote(do: {:ok, integer()} | {:error, String.t()})
    assert %Type{kind: :result, rust: "Result<i64, String>"} = RustQ.Spec.type(result_ast)

    assert %Type{kind: :tuple, rust: "(f32, f32)", meta: %{elements: [%Type{}, %Type{}]}} =
             Type.from_syn(%SynType.Tuple{
               code: "(f32, f32)",
               elems: [
                 %SynType.Path{code: "f32", name: "f32", segments: ["f32"]},
                 %SynType.Path{code: "f32", name: "f32", segments: ["f32"]}
               ]
             })

    assert %Type{kind: :slice, rust: "[u8]"} =
             Type.from_syn(%SynType.Slice{
               code: "[u8]",
               inner: %SynType.Path{code: "u8", name: "u8", segments: ["u8"]}
             })

    assert %Type{
             kind: :array,
             rust: "[u8; 4]",
             ast: %AST.TypeArray{size: "4"},
             meta: %{length: "4"}
           } =
             Type.from_syn(%SynType.Array{
               code: "[u8; 4]",
               length: "4",
               inner: %SynType.Path{code: "u8", name: "u8", segments: ["u8"]}
             })

    assert %Type{kind: :array, rust: "[u8; LEGACY]", ast: %AST.TypeRaw{}} =
             Type.from_syn(%SynType.Array{
               code: "[u8; LEGACY]",
               inner: %SynType.Path{code: "u8", name: "u8", segments: ["u8"]}
             })

    assert %Type{kind: :type, rust: "Self", ast: %AST.TypePath{parts: [:Self]}} =
             Type.from_syn(%SynType.Self{code: "Self"})

    assert %Type{
             kind: :fn,
             rust: ~s|for<'a> unsafe extern "C" fn(&'a u8, ...) -> bool|,
             ast: %AST.TypeBareFn{
               lifetimes: ["'a"],
               unsafe: true,
               external: true,
               abi: "C",
               variadic: true
             }
           } =
             Type.from_syn(%SynType.Fn{
               code: ~s|for<'a> unsafe extern "C" fn(value: &'a u8, ...) -> bool|,
               lifetimes: ["'a"],
               unsafe: true,
               external: true,
               abi: "C",
               variadic: true,
               arg_names: ["value"],
               args: [
                 %SynType.Ref{
                   code: "&'a u8",
                   lifetime: "'a",
                   inner: %SynType.Path{code: "u8", name: "u8", segments: ["u8"]}
                 }
               ],
               returns: %SynType.Path{code: "bool", name: "bool", segments: ["bool"]}
             })

    assert %Type{
             kind: :impl_trait,
             rust: "impl Into<u32> + Send",
             ast: %AST.TypeImplTrait{bounds: ["Into<u32>", "Send"]}
           } =
             Type.from_syn(%SynType.ImplTrait{
               code: "impl Into<u32> + Send",
               traits: [],
               bounds: [
                 %SynType.Bound{kind: :trait, code: "Into<u32>"},
                 %SynType.Bound{kind: :trait, code: "Send"}
               ]
             })
  end

  test "Spec exposes Syn type conversion" do
    assert %Type{kind: :bool, rust: "bool"} =
             Spec.from_syn(%SynType.Path{code: "bool", name: "bool", segments: ["bool"]})
  end

  test "keeps external t aliases as direct Rust identifiers" do
    assert RustQ.Spec.type(quote(do: ItemConst.t())).rust == "ItemConst"
    assert RustQ.Spec.type(quote(do: ItemStruct.t())).rust == "ItemStruct"
    assert RustQ.Spec.type(quote(do: Field.t())).rust == "Field"
    assert Spec.type(quote(do: External.t())).rust == "External"

    assert RustQ.Spec.type(quote(do: RustQ.Type.nif_result(ItemEnum.t()))).rust ==
             "NifResult<ItemEnum>"
  end

  test "exports non-reserved Rust vocabulary as Elixir types" do
    {:docs_v1, _annotation, _beam_language, _format, _module_doc, _metadata, docs} =
      Code.fetch_docs(RustQ.Type)

    types =
      docs
      |> Enum.filter(&match?({{:type, _, _}, _, _, _, _}, &1))
      |> MapSet.new(fn {{:type, name, arity}, _line, _signature, _doc, _metadata} ->
        {name, arity}
      end)

    assert MapSet.subset?(
             MapSet.new([
               {:unit, 0},
               {:u8, 0},
               {:u32, 0},
               {:i64, 0},
               {:f32, 0},
               {:f64, 0},
               {:ref, 1},
               {:mut_ref, 1},
               {:option, 1},
               {:result, 2},
               {:nif_result, 1},
               {:vec, 1},
               {:path, 1},
               {:path, 2},
               {:lifetime, 1},
               {:slice, 1},
               {:raw, 1}
             ]),
             types
           )
  end
end
