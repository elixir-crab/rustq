defmodule RustQ.Syn.MetadataTest do
  use ExUnit.Case, async: true

  alias RustQ.Syn
  alias RustQ.Syn.Arg
  alias RustQ.Syn.Impl
  alias RustQ.Syn.Method
  alias RustQ.Syn.MethodCall
  alias RustQ.Syn.Signature
  alias RustQ.Syn.Type

  test "parses top-level Rust metadata" do
    source = """
    /// Path operation docs.
    pub enum SkPathOp {
        Difference = 0,
        Intersect = 1,
        Union = 2,
    }

    /// Point docs.
    pub struct Point {
        pub x: f32,
        pub y: f32,
    }

    pub fn lerp(a: f32, b: f32) -> f32 {
        a + b
    }

    impl Point {
        /// Offset docs.
        pub fn offset(&mut self, dx: f32, dy: f32) -> Self {
            Self { x: self.x + dx, y: self.y + dy }
        }
    }
    """

    assert {:ok, file} = Syn.parse(source)

    assert [
             %Syn.Enum{
               name: "SkPathOp",
               visibility: :public,
               source_line: 2,
               docs: ["Path operation docs."],
               variants: ["Difference", "Intersect", "Union"]
             }
           ] = Syn.enums(file)

    assert [%Syn.Struct{name: "Point", docs: ["Point docs."], fields: fields}] =
             Syn.structs(file)

    assert [
             %Syn.Field{
               name: "x",
               type: "f32",
               type_ast: %Type.Path{name: "f32"}
             },
             %Syn.Field{name: "y", type: "f32", type_ast: %Type.Path{name: "f32"}}
           ] = fields

    assert [
             %Syn.Function{
               name: "lerp",
               source_line: 14,
               signature: "fn lerp (a : f32 , b : f32) -> f32",
               signature_ast: lerp_signature,
               args: args,
               returns: "f32"
             }
           ] =
             Syn.functions(file)

    assert Signature.render(lerp_signature) == "fn lerp(a: f32, b: f32) -> f32"

    assert [
             %Arg{name: "a", type: "f32", type_ast: %Type.Path{name: "f32"}},
             %Arg{name: "b", type: "f32", type_ast: %Type.Path{name: "f32"}}
           ] = args

    assert [
             %Impl{
               target: "Point",
               target_ast: %Type.Path{name: "Point"},
               trait: nil,
               methods: [
                 %Method{
                   name: "offset",
                   visibility: :public,
                   source_line: 20,
                   signature: "fn offset (& mut self , dx : f32 , dy : f32) -> Self",
                   signature_ast: offset_signature,
                   docs: ["Offset docs."],
                   args: method_args,
                   returns: "Self",
                   returns_ast: %Type.Self{code: "Self"}
                 }
               ]
             }
           ] = Syn.impls(file)

    assert [
             %Arg{
               name: "self",
               type: "& mut self",
               type_ast: %Type.Ref{mutable: true, inner: %Type.Self{}}
             },
             %Arg{name: "dx", type: "f32", type_ast: %Type.Path{name: "f32"}},
             %Arg{name: "dy", type: "f32", type_ast: %Type.Path{name: "f32"}}
           ] = method_args

    assert Signature.render(offset_signature) ==
             "fn offset(&mut self, dx: f32, dy: f32) -> Self"
  end

  test "parses path associated type metadata" do
    source = """
    pub fn merge(filters: impl IntoIterator<Item = Option<ImageFilter>>) {}
    """

    assert {:ok, file} = Syn.parse(source)

    assert [
             %Syn.Function{
               args: [
                 %Arg{
                   type_ast: %Type.ImplTrait{
                     traits: [
                       %Type.Path{
                         name: "IntoIterator",
                         assoc: %{"Item" => %Type.Option{inner: %Type.Path{name: "ImageFilter"}}},
                         generic_args: [
                           %Type.GenericArgument{
                             kind: :assoc_type,
                             name: "Item",
                             type: %Type.Option{inner: %Type.Path{name: "ImageFilter"}}
                           }
                         ]
                       }
                     ]
                   }
                 }
               ]
             }
           ] = Syn.functions(file)
  end

  test "preserves ordered impl Trait bounds" do
    source = "pub fn spawn(value: impl Send + 'static) {}"

    assert [
             %Syn.Function{
               args: [
                 %Arg{
                   type_ast: %Type.ImplTrait{
                     bounds: [
                       %Type.Bound{kind: :trait, code: "Send"},
                       %Type.Bound{kind: :lifetime, lifetime: "'static"}
                     ]
                   }
                 }
               ]
             }
           ] = source |> Syn.parse!() |> Syn.functions()
  end

  test "preserves precise capture impl Trait bounds" do
    source = "pub fn values(value: &str) -> impl Iterator<Item = String> + use<'_> { todo!() }"

    assert [
             %Syn.Function{
               returns_ast: %Type.ImplTrait{
                 bounds: [
                   %Type.Bound{kind: :trait, code: "Iterator < Item = String >"},
                   %Type.Bound{kind: :precise_capture, code: "use < '_ >"}
                 ]
               }
             }
           ] = source |> Syn.parse!() |> Syn.functions()
  end

  test "parses nested module free functions with module paths" do
    source = """
    pub mod color_filters {
        pub fn blend(c: impl Into<Color>, mode: BlendMode) -> Option<ColorFilter> { todo!() }
    }
    """

    assert {:ok, file} = Syn.parse(source)

    assert [
             %Syn.Function{
               name: "blend",
               module_path: ["color_filters"],
               source_line: 2,
               args: [
                 %Arg{name: "c", type_ast: %Type.ImplTrait{}},
                 %Arg{name: "mode", type_ast: %Type.Path{name: "BlendMode"}}
               ],
               returns_ast: %Type.Option{inner: %Type.Path{name: "ColorFilter"}}
             }
           ] = Syn.functions(file)
  end

  test "parses common compound type metadata" do
    source = """
    impl Canvas {
        pub fn draw_rect(&self, rect: impl AsRef<Rect>, paint: Option<&Paint>) -> Result<&Self, Error> {
            Ok(self)
        }
    }
    """

    assert [method] = source |> Syn.parse!() |> Syn.methods()

    assert %Method{
             args: [
               %Arg{type_ast: %Type.Ref{inner: %Type.Self{}}},
               %Arg{
                 type_ast: %Type.ImplTrait{
                   traits: [
                     %Type.Path{
                       name: "AsRef",
                       args: [%Type.Path{name: "Rect"}],
                       generic_args: [
                         %Type.GenericArgument{kind: :type, type: %Type.Path{name: "Rect"}}
                       ]
                     }
                   ],
                   bounds: [%Type.Bound{kind: :trait, code: "AsRef < Rect >"}]
                 }
               },
               %Arg{
                 type_ast: %Type.Option{
                   inner: %Type.Ref{inner: %Type.Path{name: "Paint"}}
                 }
               }
             ],
             returns_ast: %Type.Result{
               ok: %Type.Ref{inner: %Type.Self{}},
               error: %Type.Path{name: "Error"}
             }
           } = method
  end

  test "preserves reference lifetimes and fixed array lengths" do
    source = """
    pub fn borrow<'a, const N: usize>(values: &'a mut [u8; N]) -> &'a [u8; 4] {
        todo!()
    }
    """

    assert [
             %Syn.Function{
               signature_ast: signature,
               args: [
                 %Arg{
                   type_ast: %Type.Ref{
                     lifetime: "'a",
                     mutable: true,
                     inner: %Type.Array{length: "N", inner: %Type.Path{name: "u8"}}
                   }
                 }
               ],
               returns_ast: %Type.Ref{
                 lifetime: "'a",
                 inner: %Type.Array{length: "4", inner: %Type.Path{name: "u8"}}
               }
             }
           ] = source |> Syn.parse!() |> Syn.functions()

    assert Signature.render(signature) ==
             "fn borrow(values: &'a mut [u8; N]) -> &'a [u8; 4]"
  end

  test "preserves qualified bare function type metadata" do
    source = """
    pub fn install(callback: for<'a> unsafe extern "C" fn(value: &'a u8, count: usize, ...) -> bool) {}
    """

    assert [
             %Syn.Function{
               signature_ast: signature,
               args: [
                 %Arg{
                   type_ast: %Type.Fn{
                     lifetimes: ["'a"],
                     unsafe: true,
                     external: true,
                     abi: "C",
                     arg_names: ["value", "count"],
                     variadic: true,
                     args: [
                       %Type.Ref{lifetime: "'a", inner: %Type.Path{name: "u8"}},
                       %Type.Path{name: "usize"}
                     ],
                     returns: %Type.Path{name: "bool"}
                   }
                 }
               ]
             }
           ] = source |> Syn.parse!() |> Syn.functions()

    assert Signature.render(signature) ==
             ~s|fn install(callback: for<'a> unsafe extern "C" fn(value: &'a u8, count: usize, ...) -> bool)|
  end

  test "describes enum variant payloads and generics" do
    source = """
    pub enum Node<'a, T> {
        /// Empty docs.
        Empty,
        Leaf(Box<'a, T>, usize),
        Branch { children: Vec<'a, Node<'a, T>>, label: Option<&'a str> },
    }
    """

    assert [
             %Syn.Enum{
               name: "Node",
               variants: ["Empty", "Leaf", "Branch"],
               lifetimes: ["a"],
               type_parameters: ["T"],
               variant_shapes: [
                 %Syn.Variant{name: "Empty", kind: :unit, fields: [], docs: ["Empty docs."]},
                 %Syn.Variant{
                   name: "Leaf",
                   kind: :tuple,
                   fields: [
                     %Syn.Field{name: nil, type_ast: %Type.Path{name: "Box"}},
                     %Syn.Field{name: nil, type: "usize"}
                   ]
                 },
                 %Syn.Variant{
                   name: "Branch",
                   kind: :named,
                   fields: [
                     %Syn.Field{name: "children", type_ast: %Type.Path{name: "Vec"}},
                     %Syn.Field{name: "label", type_ast: %Type.Option{}}
                   ]
                 }
               ]
             }
           ] = source |> Syn.parse!() |> Syn.enums()
  end

  test "describes struct generics" do
    source = """
    pub struct Borrowed<'a, 'b, T: Clone> {
        pub value: &'a T,
        pub name: &'b str,
    }

    pub struct Pair(pub u8, pub u8);
    """

    assert [
             %Syn.Struct{name: "Borrowed", lifetimes: ["a", "b"], type_parameters: ["T"]},
             %Syn.Struct{
               name: "Pair",
               lifetimes: [],
               type_parameters: [],
               fields: [%Syn.Field{name: nil, type: "u8"}, %Syn.Field{name: nil, type: "u8"}]
             }
           ] = source |> Syn.parse!() |> Syn.structs()
  end

  test "returns variants for a named enum" do
    source = """
    enum Hidden { A, B }
    pub enum Shown { One, Two }
    """

    assert {:ok, ["One", "Two"]} = Syn.enum_variants(source, "Shown")
    assert {:error, "enum Missing not found"} = Syn.enum_variants(source, "Missing")
  end

  test "returns rustler atom references from parsed Rust source" do
    source = """
    fn decode(value: rustler::Atom) -> bool {
        value == atoms::ok() || value == atoms::error()
    }
    """

    assert Syn.atom_references!(source) == ["error", "ok"]
  end

  test "returns atom references through a configured Rust module" do
    source = """
    fn decode() {
        let _ = a::kind();
        let _ = atoms::ignored();
        term_map!({ a::value() => 42 });
    }
    """

    assert Syn.atom_references!(source, module: "a") == ["kind", "value"]
  end

  test "returns atom references nested in macro token trees" do
    source = """
    fn encode(env: Env) -> Term {
        term_map!(env, {
            atoms::kind() => atoms::component(),
            atoms::value() => 42,
        })
    }
    """

    assert Syn.atom_references!(source) == ["component", "kind", "value"]
  end

  test "returns receiver method references from parsed Rust source" do
    source = """
    fn draw(canvas: &Canvas, paint: &Paint) {
        canvas.save();
        canvas.draw_rect(Rect::default(), paint);
    }
    """

    assert Syn.method_references!(source) == ["draw_rect", "save"]
  end

  test "returns receiver-aware method calls from parsed Rust source" do
    source = """
    fn draw(canvas: &Canvas, state: &mut State, paint: &Paint) {
        canvas.draw_rect(Rect::default(), paint);
        state.canvas().clip_path(path, ClipOp::Intersect, true);
    }
    """

    assert Syn.method_calls!(source) == [
             %MethodCall{receiver: "canvas", method: "draw_rect"},
             %MethodCall{receiver: "state", method: "canvas"},
             %MethodCall{receiver: "state . canvas ()", method: "clip_path"}
           ]
  end
end
