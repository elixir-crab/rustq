defmodule RustQ.Rustler.TermTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rustler.{Atom, Nif, Opts, TaggedEnum, Term}

  test "builds map helper functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("opts_helpers.rs", splice: [items: Opts.helpers()])

    assert code =~ "fn decode_opts<'a>(term: Term<'a>) -> NifResult<Vec<(Atom, Term<'a>)>>"
    assert code =~ "term.map_get(atoms::opts())?"
    assert code =~ "fn decode_args<'a>(term: Term<'a>) -> NifResult<Vec<Term<'a>>>"
    assert code =~ "term.map_get(atoms::args())?"
    assert code =~ "fn opt_term<'a>(opts: &[(Atom, Term<'a>)], key: Atom) -> Option<Term<'a>>"
    assert code =~ "fn opt_f32<'a>(opts: &[(Atom, Term<'a>)], key: Atom) -> NifResult<f32>"
    assert code =~ "fn opt_atom_option<'a>"
    assert code =~ "Ok(Some(term.decode::<f64>()? as f32))"
    assert code =~ "Ok(Some(term.decode::<bool>()?))"
    assert code =~ "Ok(Some(term.decode::<Atom>()?))"
  end

  test "builds cached atom functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("cached_atoms.rs",
        splice: [items: Atom.cached([:ok, {:node_changes, "nodeChanges"}])]
      )

    assert code =~ "fn cached_atom(env: Env, cell: &OnceLock<Atom>, name: &str) -> Atom"
    assert code =~ "static OK_ATOM: OnceLock<Atom> = OnceLock::new();"
    assert code =~ "fn ok_atom(env: Env) -> Atom"
    assert code =~ ~S/cached_atom(env, &NODE_CHANGES_ATOM, "nodeChanges")/
  end

  test "builds term builder helpers" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_builders.rs", splice: [items: Term.builders()])

    assert code =~ "fn make_map_from_terms<'a>"
    assert code =~ "fn make_struct_from_terms<'a>"
    assert code =~ "Term::map_from_term_arrays"
  end

  test "builds fixed struct term helpers" do
    code =
      "__rq_items!();"
      |> RustQ.render!("fixed_struct_helpers.rs",
        splice: [
          items:
            Term.helpers(
              include: [
                :cached_struct_keys,
                :default_struct_values,
                :make_struct_from_arrays
              ]
            )
        ]
      )

    assert code =~ "fn cached_struct_keys"
    assert code =~ "OnceLock<Vec<Atom>>"
    assert code =~ "fn default_struct_values"
    assert code =~ "fn make_struct_from_arrays<'a>"
    assert code =~ "Term::map_from_term_arrays"
  end

  test "builds NifStruct declarations" do
    code =
      "__rq_items!();"
      |> RustQ.render!("nif_struct.rs",
        splice: [
          items: [
            Nif.struct(:ExText, "Folio.Content.Text",
              fields: [
                text: :String,
                size: {:option, :String}
              ]
            )
          ]
        ]
      )

    assert code =~ "#[derive(Clone, Debug, NifStruct)]"
    assert code =~ ~S/#[module = "Folio.Content.Text"]/
    assert code =~ "pub struct ExText"
    assert code =~ "pub text: String"
    assert code =~ "pub size: Option<String>"
  end

  test "builds tagged enum decoder and encoder declarations" do
    code =
      "__rq_items!();"
      |> RustQ.render!("tagged_enum.rs",
        splice: [
          items:
            TaggedEnum.items(:ExContent,
              tag: A.call(:atom_struct),
              attrs: [A.allow_attr(:dead_code)],
              variants: [
                Text: [type: :ExText, module: "Elixir.Folio.Content.Text"],
                Space: [type: :ExSpace, module: "Elixir.Folio.Content.Space"]
              ]
            )
        ]
      )

    assert code =~ "#[allow(dead_code)]"
    assert code =~ "pub enum ExContent"
    assert code =~ "Text(ExText)"
    assert code =~ "impl<'a> rustler::Decoder<'a> for ExContent"
    assert code =~ ~S/"Elixir.Folio.Content.Text"/
    assert code =~ "Ok(ExContent::Text(rustler::Decoder::decode(term)?))"
    assert code =~ "impl rustler::Encoder for ExContent"
    assert code =~ "ExContent::Text(value) => value.encode(env)"
  end

  test "builds term helper functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_helpers.rs",
        splice: [items: Term.helpers(type_key: "a::r#type()")]
      )

    assert code =~ "fn get<'a>(term: Term<'a>, key: rustler::Atom) -> Option<Term<'a>>"
    assert code =~ "fn opt<'a>(term: Term<'a>, key: rustler::Atom) -> Option<Term<'a>>"
    assert code =~ "get(term, key).filter(|value| !is_nil(*value))"
    assert code =~ "fn str_val<'a>(term: Term<'a>, key: rustler::Atom) -> String"
    assert code =~ "get(term, atoms::r#type())"
  end

  test "builds term decoders" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_decoder.rs",
        splice: [
          items:
            Term.decoder(:User,
              fields: [
                id: [type: :i64, key: "a::id()", required: true],
                name: [type: :String, key: "a::name()", required: true],
                active: [type: :bool, key: "a::active()", default: "false"],
                email: [type: {:option, :String}, key: "a::email()"],
                body: [type: {:vec, "Term<'a>"}, decode: "list_val(term, a::body())"]
              ]
            )
        ]
      )

    assert code =~ "struct User<'a>"
    assert code =~ "fn decode_user<'a>(term: Term<'a>) -> NifResult<User<'a>>"
    assert code =~ "id: term.map_get(a::id())?.decode::<i64>()?"
    assert code =~ "name: term.map_get(a::name())?.decode::<String>()?"
    assert code =~ "unwrap_or(false)"
    assert code =~ "email: term"
    assert code =~ ".map_get(a::email())"
    assert code =~ ".and_then(|term| term.decode::<String>().ok())"
    assert code =~ "body: list_val(term, a::body())"
  end

  test "keeps structural term decoder inputs AST-backed" do
    [_struct, decoder] =
      Term.decoder(:User,
        fields: [
          active: [type: :bool, key: A.call(:active_key), default: false],
          body: [type: {:vec, "Term<'a>"}, decode: A.call(:decode_body, [:term])]
        ]
      )

    refute inspect(decoder) =~ "EscapeExpr"
  end

  test "builds term decoders with custom result aliases" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_decoder.rs",
        splice: [
          items:
            Term.decoder(:IfStatementInput,
              result: "R",
              fields: [
                test: [type: "Term<'a>", key: "a::test()", required: true],
                alternate: [type: {:option, "Term<'a>"}, key: "a::alternate()"]
              ]
            )
        ]
      )

    assert code =~ "fn decode_if_statement_input<'a>(term: Term<'a>) -> R<IfStatementInput<'a>>"
    assert code =~ ~S/map_err(|_| "Missing :test".to_string())?/
    assert code =~ ~S/map_err(|_| "Invalid :test".to_string())?/
    assert code =~ "alternate: term"
    assert code =~ ".map_get(a::alternate())"
  end

  test "builds term decoders with custom required error messages" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_decoder.rs",
        splice: [
          items:
            Term.decoder(:IfStatementInput,
              result: "R",
              fields: [
                test: [
                  type: "Term<'a>",
                  key: "a::test()",
                  required: true,
                  missing: "Missing condition",
                  invalid: "Invalid condition"
                ]
              ]
            )
        ]
      )

    assert code =~ ~S/map_err(|_| "Missing condition".to_string())?/
    assert code =~ ~S/map_err(|_| "Invalid condition".to_string())?/
  end

  test "selects term helper functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_helpers.rs",
        splice: [items: Term.helpers(include: [:get, :str_val])]
      )

    assert code =~ "fn get<'a>"
    assert code =~ "fn str_val<'a>"
    refute code =~ "fn bool_val"
    refute code =~ "fn type_atom"
  end

  test "builds atom-keyed term encoder implementations" do
    manifest = [fields: [:start, {:end_, :end}], target_lifetimes: [:_]]

    assert Term.encoder_atom_names(manifest) == ["start", "end_"]

    code =
      "__rq_items!();"
      |> RustQ.render!("term_encoder.rs",
        splice: [
          items: Term.encoder(:EncodedLoc, manifest)
        ]
      )

    assert code =~ "impl rustler::Encoder for EncodedLoc<'_>"
    assert code =~ "fn encode<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a>"
    assert code =~ "atoms::start().encode(env)"
    assert code =~ "atoms::end_().encode(env)"
    assert code =~ "self.end.encode(env)"
    assert code =~ "Term::map_from_arrays"
  end

  test "builds term encoders with nested and transformed fields" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_encoder.rs",
        splice: [
          items:
            Term.encoder(:EncodedBlock,
              fields: [
                content: [field: [0, :content], via: :as_ref],
                lang: [field: [0, :lang], via: :as_deref],
                loc: [field: [0, :loc], with: :loc_to_term],
                exports: [
                  field: [0, :exports],
                  via: :as_ref,
                  with: :encode_exports,
                  borrow: false
                ],
                code: [field: :code_override, fallback: [field: [:result, :code], via: :as_str]]
              ],
              target_lifetimes: [:_]
            )
        ]
      )

    assert code =~ "self.0.content.as_ref().encode(env)"
    assert code =~ "self.0.lang.as_deref().encode(env)"
    assert code =~ "loc_to_term(env, &self.0.loc)"
    assert code =~ "encode_exports(env, self.0.exports.as_ref())"
    assert code =~ "self.code_override.unwrap_or(self.result.code.as_str()).encode(env)"
  end

  test "builds mapped and optional adapter fields" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_encoder.rs",
        splice: [
          items:
            Term.encoder(:EncodedResult,
              fields: [
                template: [field: [:descriptor, :template], optional: [wrap: :EncodedTemplate]],
                styles: [field: [:descriptor, :styles], map: [wrap: :EncodedStyle]],
                errors: [field: [:result, :errors], map: [convert: :EncodedError]],
                warnings: [field: [:result, :warnings], map: [via: :as_str]],
                ast: [field: [:result, :ast], optional: [with: :encode_json_value]]
              ],
              target_lifetimes: [:_]
            )
        ]
      )

    assert code =~ ".template"
    assert code =~ ".map(|value| EncodedTemplate(value).encode(env))"
    assert code =~ ".unwrap_or_else(|| nil_term(env))"
    assert code =~ ".styles"
    assert code =~ ".map(|value| EncodedStyle(value).encode(env))"
    assert code =~ "collect::<Vec<Term<'a>>>()"
    assert code =~ ".encode(env)"
    assert code =~ "EncodedError::from(value).encode(env)"
    assert code =~ "value.as_str().encode(env)"
    assert code =~ "encode_json_value(env, value)"
  end

  test "builds term encoders with conditional option fields" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_encoder.rs",
        splice: [
          items:
            Term.encoder(:EncodedError,
              fields: [
                :message,
                code: [field: [0, :module_code], when_some: true, via: :as_str]
              ],
              target_lifetimes: [:_]
            )
        ]
      )

    assert code =~ "let mut keys = vec![atoms::message().encode(env)]"
    assert code =~ "if let Some(value) = self.0.module_code.as_ref()"
    assert code =~ "keys.push(atoms::code().encode(env))"
    assert code =~ "values.push(value.as_str().encode(env))"
    assert code =~ "Term::map_from_arrays(env, &keys, &values)"
  end

  test "builds forgiving optional map decoders" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_helpers.rs",
        splice: [
          items:
            Term.helpers(
              include: [
                :get,
                :get_bool,
                :get_i64,
                :get_string,
                :get_optional_string,
                :get_string_list,
                :get_term_list,
                :get_map
              ]
            )
        ]
      )

    assert code =~ "fn get_bool<'a>"
    assert code =~ "fn get_i64<'a>"
    assert code =~ "fn get_string<'a>"
    assert code =~ "fn get_optional_string<'a>"
    assert code =~ "if is_nil(value) { Some(None) }"
    assert code =~ "get_string(term, key).map(Some)"
    assert code =~ "None => None"
    refute code =~ "Some(Some(None))"
    assert code =~ "fn get_string_list<'a>"
    assert code =~ "fn get_term_list<'a>"
    assert code =~ "fn get_map<'a>"
    assert code =~ "value.decode::<Vec<String>>()"
    assert code =~ "get(term, key).filter(|value| value.is_map())"
  end

  test "supports explicit all term helper selection" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_helpers.rs",
        splice: [items: Term.helpers(include: :all)]
      )

    assert code =~ "fn get<'a>"
    assert code =~ "fn type_str"
  end

  test "excludes term helper functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("term_helpers.rs",
        splice: [items: Term.helpers(exclude: [:f64_val, :type_str])]
      )

    assert code =~ "fn get<'a>"
    refute code =~ "fn f64_val"
    refute code =~ "fn type_str"
  end

  describe "encoders from source" do
    alias RustQ.Rustler.{Atom, Term}
    alias RustQ.Syn.Index

    @describetag :tmp_dir

    # SetProp has its own `kind` field, which a `kind` tag would replace.
    @set_prop_kind [fields: [kind: [key: :prop_kind]]]

    @ir """
    use std::collections::HashMap;

    pub struct Loc { pub start: u32, pub end: u32 }
    pub struct Expr<'a> { pub content: &'a str, pub is_static: bool }
    pub struct Name(pub String);
    pub enum Kind { Regular, KeepAlive }

    pub struct SetProp<'a> {
        pub element: usize,
        pub values: Vec<Box<Expr<'a>>>,
        pub loc: Option<Loc>,
        pub kind: Kind,
        pub r#type: Name,
        pub attrs: HashMap<String, Expr<'a>>,
    }

    pub enum Op<'a> {
        SetProp(SetProp<'a>),
        Text { element: usize, values: Vec<Expr<'a>> },
        Anchor(usize),
        Pair(u32, u32),
        Clear,
    }
    """

    test "builds one encoder per reachable type", %{tmp_dir: tmp_dir} do
      code = render!(tmp_dir, @ir, ["Op"])

      for name <- ~w(op set_prop expr loc kind name) do
        assert code =~ "pub(crate) fn encode_#{name}<'a>"
      end

      assert code =~
               "fn encode_op<'a>(env: rustler::Env<'a>, value: &Op<'_>) -> rustler::Term<'a>"

      assert code =~ "fn encode_loc<'a>(env: rustler::Env<'a>, value: &Loc) -> rustler::Term<'a>"
      assert RustQ.valid?(code, "term_source.rs")
    end

    test "encodes fields through their wrappers", %{tmp_dir: tmp_dir} do
      code = render!(tmp_dir, @ir, ["SetProp"])

      assert code =~ "value.element.encode(env)"
      assert code =~ ".map(|item0| encode_expr(env, item0))"
      assert code =~ ".unwrap_or_else(|| rustler::types::atom::nil().encode(env))"
      assert code =~ "encode_name(env, &value.r#type)"
      assert code =~ "rustler::Term::map_from_pairs"
      assert code =~ "value.0.as_str().encode(env)"
      assert code =~ "value.content.encode(env)"
    end

    test "tags data-carrying variants and keeps unit-only enums as atoms", %{tmp_dir: tmp_dir} do
      code = render!(tmp_dir, @ir, ["Op"], tag: :kind, types: [SetProp: @set_prop_kind])

      assert code =~ ".map_put(atoms::kind().encode(env), atoms::set_prop().encode(env))"
      assert code =~ "Op::Text { element, values } =>"
      assert code =~ "&[atoms::kind().encode(env), atoms::value().encode(env)]"

      assert code =~ ~r/make_tuple\(\s*env,\s*&\[field0\.encode\(env\), field1\.encode\(env\)\]/

      assert code =~ "Kind::KeepAlive => atoms::keep_alive().encode(env)"
    end

    test "encodes payloads transparently without a tag", %{tmp_dir: tmp_dir} do
      code = render!(tmp_dir, @ir, ["Op"])

      assert code =~ "Op::SetProp(field0) => encode_set_prop(env, field0)"
      assert code =~ "Op::Anchor(field0) => field0.encode(env)"
      assert code =~ "Op::Clear => atoms::clear().encode(env)"
    end

    test "applies per-type policy", %{tmp_dir: tmp_dir} do
      code =
        render!(tmp_dir, @ir, ["Op"],
          tag: :kind,
          external: [Expr: :encode_expression],
          types: [
            SetProp: [
              except: [:attrs],
              fields: [
                element: [key: :el],
                loc: [with: [:locs, :encode]],
                kind: [key: :prop_kind]
              ]
            ],
            Op: [variants: [Clear: :reset]],
            Kind: [tag: false]
          ]
        )

      refute code =~ "fn encode_expr<"
      assert code =~ "encode_expression(env, item0)"
      refute code =~ "atoms::attrs()"
      assert code =~ "atoms::el().encode(env)"
      assert code =~ "locs::encode(env, &value.loc)"
      refute code =~ "fn encode_loc<"
      assert code =~ "atoms::reset().encode(env)"
    end

    test "returns atom declarations derived from the same source", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, @ir)

      atoms =
        Term.encoder_atoms_from_source([path], ["Op"],
          tag: :kind,
          types: [SetProp: @set_prop_kind]
        )

      assert {:type, "type"} in atoms
      assert "set_prop" in atoms
      assert "keep_alive" in atoms
      assert "kind" in atoms
      assert "value" in atoms

      code =
        RustQ.render!("__rq_items!();", "atoms.rs", splice: [items: [Atom.declaration(atoms)]])

      assert code =~ ~S|r#type = "type"|
    end

    test "accepts an index and extra wrapper names", %{tmp_dir: tmp_dir} do
      path =
        write!(tmp_dir, """
        pub struct Leaf { pub id: u32 }
        pub struct Tree<'a> { pub leaves: ArenaVec<'a, ArenaBox<'a, Leaf>> }
        """)

      index = Index.from_paths([path])

      code =
        index
        |> Term.encoders_from_source(["Tree"],
          wrappers: [sequence: [:ArenaVec], pointer: [:ArenaBox]]
        )
        |> render!()

      assert code =~ ".map(|item0| encode_leaf(env, item0))"
    end

    test "reports unmapped, ambiguous, and generic types", %{tmp_dir: tmp_dir} do
      path =
        write!(tmp_dir, """
        pub struct Holder { pub span: Span, pub list: Generic<u8>, pub pair: (u8, u8) }
        pub struct Generic<T> { pub value: T }
        """)

      message =
        assert_raise ArgumentError, fn -> Term.encoders_from_source([path], ["Holder"]) end

      assert message.message =~ "Span (used by Holder) is not in the index"
      refute message.message =~ "already has"
      assert message.message =~ "Generic has type parameters (T)"
      assert message.message =~ ~r/\(u8 ?, u8\) \(used by Holder\) has no encoding/

      assert_raise ArgumentError, ~r/root type Missing is not in the index/, fn ->
        Term.encoders_from_source([path], ["Missing"])
      end

      other = Path.join(tmp_dir, "other.rs")
      File.write!(other, "pub struct Holder { pub id: u8 }\n")

      assert_raise ArgumentError, ~r/Holder is defined in several sources/, fn ->
        Term.encoders_from_source([path, other], ["Holder"])
      end
    end

    test "rejects a tag that would replace a payload field", %{tmp_dir: tmp_dir} do
      path =
        write!(tmp_dir, """
        pub struct Component { pub kind: u8 }
        pub enum Op { Create(Component), Named { kind: u8 } }
        """)

      error =
        assert_raise ArgumentError, fn ->
          Term.encoders_from_source([path], ["Op"], tag: :kind)
        end

      assert error.message =~ "Op::Create already has a kind field"
      assert error.message =~ "Op::Named already has a kind field"

      code =
        [path]
        |> Term.encoders_from_source(["Op"],
          tag: :kind,
          types: [
            Component: [fields: [kind: [key: :value]]],
            Op: [fields: [kind: [key: :component_kind]]]
          ]
        )
        |> render!()

      assert code =~ "atoms::value().encode(env)"
      assert code =~ "atoms::component_kind().encode(env)"
    end

    test "encodes a transparent struct as its only field", %{tmp_dir: tmp_dir} do
      source = """
      pub struct Effect { pub operations: Vec<u32> }
      pub struct Pair { pub left: u32, pub right: u32 }
      pub struct Block { pub effects: Vec<Effect>, pub pair: Pair }
      """

      path = write!(tmp_dir, source)
      opts = [types: [Effect: [transparent: true]]]
      code = [path] |> Term.encoders_from_source(["Block"], opts) |> render!()

      assert code =~ ~r/fn encode_effect<'a>\(\s*env: rustler::Env<'a>,\s*value: &Effect,?\s*\)/
      assert code =~ ~r/fn encode_effect.*\{\s*value\s*\.operations\s*\.iter\(\)/s
      refute "operations" in Term.encoder_atoms_from_source([path], ["Block"], opts)

      assert_raise ArgumentError, ~r/Pair is transparent but has 2 fields/, fn ->
        Term.encoders_from_source([path], ["Block"], types: [Pair: [transparent: true]])
      end
    end

    test "lists every user of an unmapped type once", %{tmp_dir: tmp_dir} do
      path =
        write!(tmp_dir, """
        pub struct First { pub span: Span }
        pub struct Second { pub span: Span, pub first: First }
        """)

      error = assert_raise ArgumentError, fn -> Term.encoders_from_source([path], ["Second"]) end
      assert error.message =~ "Span (used by First, Second) is not in the index"
    end

    defp render!(tmp_dir, source, roots, opts \\ []) do
      tmp_dir
      |> write!(source)
      |> List.wrap()
      |> Term.encoders_from_source(roots, opts)
      |> render!()
    end

    defp render!(items),
      do: RustQ.render!("__rq_items!();", "term_source.rs", splice: [items: items])

    defp write!(tmp_dir, source) do
      path = Path.join(tmp_dir, "ir.rs")
      File.write!(path, source)
      path
    end
  end
end
