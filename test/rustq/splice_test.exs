defmodule RustQ.SpliceTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust

  test "splices top-level items" do
    code =
      "__rq_items!();"
      |> RustQ.render!("items.rs", splice: [items: ["pub mod users;", "pub mod posts;"]])

    assert code =~ "pub mod users;"
    assert code =~ "pub mod posts;"
  end

  test "splices multi-item generated blocks" do
    code =
      "__rq_items!();"
      |> RustQ.render!("items.rs",
        splice: [
          items: [
            """
            #[derive(Clone, Copy, Eq, Hash, PartialEq)]
            struct GraphFocusGuid { session_id: u32, local_id: u32 }

            fn graph_focus_parse_guid(value: &str) -> Option<GraphFocusGuid> {
                let (session_id, local_id) = value.split_once(':')?;
                Some(GraphFocusGuid { session_id: session_id.parse().ok()?, local_id: local_id.parse().ok()? })
            }
            """
          ]
        ]
      )

    assert code =~ "#[derive(Clone, Copy, Eq, Hash, PartialEq)]"
    assert code =~ "struct GraphFocusGuid"
    assert code =~ "fn graph_focus_parse_guid"
  end

  test "splices multi-impl-item generated blocks" do
    code =
      "impl Target { __rq_items!(); }"
      |> RustQ.render!("impl_items.rs",
        splice: [items: ["fn one(&self) {}\nfn two(&self) -> i32 { 2 }"]]
      )

    assert code =~ "fn one(&self)"
    assert code =~ "fn two(&self) -> i32"
  end

  test "splices statements into blocks" do
    code =
      """
      pub fn run() {
          __rq_body!();
      }
      """
      |> RustQ.render!("statements.rs", splice: [body: ["let x = 1;", "drop(x);"]])

    assert code =~ "let x = 1;"
    assert code =~ "drop(x);"
  end

  test "splices match arms" do
    code =
      """
      pub fn value(input: Option<i32>) -> i32 {
          match input {
              __rq_arms => unreachable!(),
          }
      }
      """
      |> RustQ.render!("arms.rs",
        splice: [
          arms: [
            Rust.fragment(:arm, "Some(value) => value,"),
            Rust.fragment(:arm, "None => 0,")
          ]
        ]
      )

    assert code =~ "Some(value) => value"
    assert code =~ "None => 0"
    refute code =~ "unreachable"
  end

  describe "merge" do
    test "merges nested splice sources by concatenating duplicate names" do
      splices =
        RustQ.Splice.merge([
          [items: "pub fn one() {}"],
          %{items: "pub fn two() {}", more: "pub fn three() {}"},
          [items: ["pub fn four() {}"]]
        ])

      assert splices[:items] == ["pub fn one() {}", "pub fn two() {}", "pub fn four() {}"]
      assert splices[:more] == ["pub fn three() {}"]
    end

    test "template splice accepts nested splice sources" do
      splices = [
        [items: "pub fn one() -> i32 { 1 }"],
        [items: "pub fn two() -> i32 { 2 }"]
      ]

      code =
        "mod generated { __rq_items!(); }"
        |> RustQ.parse!("generated.rs")
        |> RustQ.splice(splices)
        |> RustQ.render!()

      assert code =~ "pub fn one() -> i32"
      assert code =~ "pub fn two() -> i32"
    end
  end
end
