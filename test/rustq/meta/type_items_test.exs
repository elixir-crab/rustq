defmodule RustQ.Meta.ResourceTypeCase do
  use RustQ.Meta
  alias RustQ.Type, as: R

  @type counter_state :: %{required(:value) => integer()}
  @type counter :: R.resource(counter_state())
end

defmodule RustQ.Meta.PrivateTypeCase do
  use RustQ.Meta
  alias RustQ.Type, as: R

  @typep index :: %{required(:records) => R.vec(Record.t()), required(:size) => R.usize()}
  @typep kind :: :plain | :fancy

  @spec size(R.ref(index())) :: R.usize()
  defrust(size(index), do: index.size)

  @spec fancy(kind()) :: R.bool()
  defrust(fancy(kind), do: kind == enum_variant(Kind, :fancy))
end

defmodule RustQ.Meta.TypeItemsTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.GeneratedCase, as: Generated
  alias RustQ.Meta.{PrivateTypeCase, ResourceTypeCase, Type}

  test "resource aliases preserve their structural inner type" do
    assert %Type{kind: :resource} =
             resource =
             ResourceTypeCase.__rustq_types__()[{:counter, 0}]

    assert %Type{kind: :struct} = Type.inner(resource)
  end

  test "set-theoretic type aliases are available to specs" do
    assert %RustQ.Meta.Type{kind: :enum, rust: "Mode", meta: %{variants: [:src_over, :multiply]}} =
             Generated.__rustq_types__()[{:mode, 0}]

    assert %RustQ.Meta.Type{kind: :struct, rust: "Click", meta: %{fields: click_fields}} =
             Generated.__rustq_types__()[{:click, 0}]

    assert Enum.any?(
             click_fields,
             &match?({:name, %RustQ.Meta.Type{rust: "String"}, :required}, &1)
           )

    assert %RustQ.Meta.Type{kind: :tuple_enum, rust: "Event", meta: %{variants: event_variants}} =
             Generated.__rustq_types__()[{:event, 0}]

    assert {:Click, [%RustQ.Meta.Type{rust: "Click"}]} = List.keyfind(event_variants, :Click, 0)

    assert {:Resize, [%RustQ.Meta.Type{rust: "Resize"}]} =
             List.keyfind(event_variants, :Resize, 0)

    assert {:Scroll, [%RustQ.Meta.Type{rust: "Scroll"}]} =
             List.keyfind(event_variants, :Scroll, 0)

    assert %RustQ.Meta.Type{
             kind: :struct,
             rust: "RectOpts<'a>",
             ast: %RustQ.Rust.AST.TypePath{parts: ["RectOpts"], lifetimes: [:a]},
             meta: %{fields: fields}
           } = Generated.__rustq_types__()[{:rect_opts, 0}]

    assert Enum.any?(fields, &match?({:x, %RustQ.Meta.Type{rust: "f32"}, :required}, &1))
    assert Enum.any?(fields, &match?({:fill, %RustQ.Meta.Type{rust: "Term<'a>"}, :optional}, &1))

    assert %RustQ.Meta.Type{
             kind: :struct,
             rust: "NestedOpts<'a>",
             ast: %RustQ.Rust.AST.TypePath{parts: ["NestedOpts"], lifetimes: [:a]},
             meta: %{fields: nested_fields}
           } = Generated.__rustq_types__()[{:nested_opts, 0}]

    assert Enum.any?(
             nested_fields,
             &match?(
               {:rect,
                %RustQ.Meta.Type{
                  ast: %RustQ.Rust.AST.TypePath{parts: ["RectOpts"], lifetimes: [:a]}
                }, :required},
               &1
             )
           )

    assert Enum.any?(
             nested_fields,
             &match?({:label, %RustQ.Meta.Type{rust: "String"}, :optional}, &1)
           )
  end

  test "external t types keep structured generic arguments" do
    assert %RustQ.Meta.Type{
             rust: "MyMap<String, u32>",
             ast: %RustQ.Rust.AST.TypePath{
               parts: [:MyMap],
               generics: [
                 %RustQ.Rust.AST.TypePath{parts: [:String]},
                 %RustQ.Rust.AST.TypePath{parts: [:u32]}
               ]
             }
           } = RustQ.Spec.type(quote(do: MyMap.t(String.t(), R.u32())))
  end

  test "raw aliases and Rust-only structs/enums generate declarations without decoders" do
    type_asts = Generated.__rustq_type_asts__()
    source = Generated.__rustq_source__()

    assert %RustQ.Rust.AST.TypeAlias{name: :Callback, type: %RustQ.Rust.AST.TypeRaw{}} =
             Enum.find(type_asts, &match?(%RustQ.Rust.AST.TypeAlias{name: :Callback}, &1))

    assert %RustQ.Rust.AST.Enum{
             name: :CallbackKind,
             variants: [
               %RustQ.Rust.AST.EnumVariant{
                 name: :One,
                 tuple: [%RustQ.Rust.AST.TypePath{parts: ["Callback"]}]
               },
               %RustQ.Rust.AST.EnumVariant{
                 name: :Repeated,
                 tuple: [%RustQ.Rust.AST.TypePath{parts: ["Callback"]}]
               },
               %RustQ.Rust.AST.EnumVariant{name: :Disabled, tuple: []}
             ]
           } = Enum.find(type_asts, &match?(%RustQ.Rust.AST.Enum{name: :CallbackKind}, &1))

    assert %RustQ.Rust.AST.Struct{name: :CallbackDescriptor} =
             Enum.find(type_asts, &match?(%RustQ.Rust.AST.Struct{name: :CallbackDescriptor}, &1))

    assert source =~ "pub type Callback = fn(u32) -> u32;"
    assert source =~ "pub enum CallbackKind"
    assert source =~ "One(Callback),"
    assert source =~ "Disabled,"
    assert source =~ "pub struct CallbackDescriptor"
    refute source =~ "decode_callback_descriptor"
    refute source =~ "decode_callback_kind"
  end

  test "type aliases generate structural Rust ASTs and decoders" do
    type_asts = Generated.__rustq_type_asts__()

    assert %RustQ.Rust.AST.Enum{
             name: :Mode,
             derive: [:Clone, :Copy, :Debug, :Eq, :PartialEq],
             variants: [
               %RustQ.Rust.AST.EnumVariant{name: :SrcOver},
               %RustQ.Rust.AST.EnumVariant{name: :Multiply}
             ]
           } = Enum.find(type_asts, &match?(%RustQ.Rust.AST.Enum{name: :Mode}, &1))

    assert %RustQ.Rust.AST.Function{
             name: :decode_mode_atom,
             args: [
               %RustQ.Rust.AST.FunctionArg{
                 name: :value,
                 type: %RustQ.Rust.AST.TypePath{parts: [:Atom]}
               }
             ],
             body: [
               %RustQ.Rust.AST.Return{
                 expr: %RustQ.Rust.AST.Match{
                   arms: [
                     _,
                     _,
                     %RustQ.Rust.AST.Arm{
                       pattern: %RustQ.Rust.AST.PatWildcard{},
                       body: [%RustQ.Rust.AST.Return{expr: %RustQ.Rust.AST.Err{}}]
                     }
                   ]
                 }
               }
             ]
           } =
             Enum.find(type_asts, &match?(%RustQ.Rust.AST.Function{name: :decode_mode_atom}, &1))

    assert %RustQ.Rust.AST.Struct{
             name: :NestedOpts,
             lifetimes: [:a],
             fields: [
               %RustQ.Rust.AST.StructField{
                 name: :rect,
                 type: %RustQ.Rust.AST.TypePath{parts: ["RectOpts"], lifetimes: [:a]}
               },
               %RustQ.Rust.AST.StructField{
                 name: :label,
                 type: %RustQ.Rust.AST.TypeOption{
                   inner: %RustQ.Rust.AST.TypePath{parts: [:String]}
                 }
               }
             ]
           } = Enum.find(type_asts, &match?(%RustQ.Rust.AST.Struct{name: :NestedOpts}, &1))

    assert %RustQ.Rust.AST.Enum{
             name: :Event,
             variants: [
               %RustQ.Rust.AST.EnumVariant{
                 name: :Click,
                 tuple: [%RustQ.Rust.AST.TypePath{parts: ["Click"]}]
               },
               %RustQ.Rust.AST.EnumVariant{
                 name: :Resize,
                 tuple: [%RustQ.Rust.AST.TypePath{parts: ["Resize"]}]
               },
               %RustQ.Rust.AST.EnumVariant{
                 name: :Scroll,
                 tuple: [%RustQ.Rust.AST.TypePath{parts: ["Scroll"]}]
               }
             ]
           } = Enum.find(type_asts, &match?(%RustQ.Rust.AST.Enum{name: :Event}, &1))
  end

  test "private types are Rust-only and get no term decoders" do
    source = PrivateTypeCase.__rustq_source__()

    assert source =~ "pub struct Index {"
    assert source =~ "pub records: Vec<Record>,"
    assert source =~ "pub enum Kind {"
    refute source =~ "fn decode_index"
    refute source =~ "fn decode_kind"
  end
end
