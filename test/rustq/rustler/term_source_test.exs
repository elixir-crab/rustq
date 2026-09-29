defmodule RustQ.RustlerTermSourceTest do
  use ExUnit.Case, async: true

  alias RustQ.Rustler.{Atom, Term}
  alias RustQ.Syn.Index

  @moduletag :tmp_dir

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

    assert code =~ "fn encode_op<'a>(env: rustler::Env<'a>, value: &Op<'_>) -> rustler::Term<'a>"
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
    code = render!(tmp_dir, @ir, ["Op"], tag: :kind)

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
            fields: [element: [key: :el], loc: [with: [:locs, :encode]]]
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
    atoms = Term.encoder_atoms_from_source([path], ["Op"], tag: :kind)

    assert {:type, "type"} in atoms
    assert "set_prop" in atoms
    assert "keep_alive" in atoms
    assert "kind" in atoms
    assert "value" in atoms

    code = RustQ.render!("__rq_items!();", "atoms.rs", splice: [items: [Atom.declaration(atoms)]])
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
