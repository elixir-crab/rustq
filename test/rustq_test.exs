defmodule RustQTest do
  use ExUnit.Case, async: true

  describe "parse" do
    alias RustQ.Rust

    test "parse validates templates" do
      assert {:ok, %RustQ.Template{filename: "ok.rs"}} = RustQ.parse("fn ok() {}", "ok.rs")
      assert RustQ.valid?("fn ok() {}", "ok.rs")

      assert {:error, [error]} = RustQ.parse("fn broken(", "broken.rs")
      refute RustQ.valid?("fn broken(", "broken.rs")
      assert error.type == :invalid_template
      assert error.context == :template
      assert error.filename == "broken.rs"
    end

    test "parses fragments" do
      assert {:ok, %RustQ.Rust.Fragment{kind: :field}} =
               RustQ.parse_fragment(:field, "pub id: i64")

      assert RustQ.valid_fragment?(:arm, Rust.fragment(:arm, "Some(value) => value,"))
      refute RustQ.valid_fragment?(:stmt, "let =")

      assert {:error, [%{type: :invalid_splice, context: :stmt}]} =
               RustQ.parse_fragment(:stmt, "let =")
    end
  end

  describe "render" do
    alias RustQ.Rust
    alias RustQ.Rust.AST.Builder, as: A
    alias RustQ.Rust.AST.ItemBuilder, as: I

    import RustQ.Rust.AST.ItemBuilder, only: [function: 3]

    require A
    require I

    test "binds identifiers, expressions, and splices fields/methods" do
      template = """
      pub struct __rq_Resource {
          __rq_fields: (),
      }

      impl __rq_Resource {
          __rq_methods!();

          pub fn table() -> &'static str {
              __rq_table_name!()
          }
      }
      """

      code =
        template
        |> RustQ.parse!("resource.rs")
        |> RustQ.bind(Resource: :User, table_name: {:literal, "users"})
        |> RustQ.splice(:fields, [
          I.field(:id, :i64, vis: :pub),
          I.field(:name, :String, vis: :pub)
        ])
        |> RustQ.splice(:methods, [
          function :new,
            vis: :pub,
            args: [id: :i64, name: :String],
            returns: :Self do
            A.return(A.struct_expr(:Self, id: A.var(:id), name: A.var(:name)))
          end
        ])
        |> RustQ.render!()

      assert code =~ "pub struct User"
      assert code =~ "pub id: i64"
      assert code =~ "pub name: String"
      assert code =~ "pub fn new(id: i64, name: String) -> Self"
      assert code =~ ~s("users")
    end

    test "does not replace placeholders inside Rust macro token trees" do
      code =
        "fn log() { println!(\"{}\", __rq_value!()); }"
        |> RustQ.render!("macro.rs", bind: [value: {:literal, "hello"}])

      assert code =~ "__rq_value!()"
    end

    test "renders type bindings" do
      code =
        "type MaybeUser = __rq_user!();"
        |> RustQ.render!("types.rs", bind: [user: {:type, {:option, :User}}])

      assert code =~ "type MaybeUser = Option<User>;"
    end

    test "optionally formats generated code with rustfmt" do
      assert RustQ.render!("fn answer()->i32{42}", "answer.rs", rustfmt: true) ==
               "fn answer() -> i32 {\n    42\n}\n"
    end

    test "returns structured rustfmt errors" do
      assert {:error,
              [%{type: :rustfmt_error, command: "definitely-not-rustfmt", reason: :enoent}]} =
               RustQ.render("fn answer()->i32{42}", "answer.rs",
                 rustfmt: "definitely-not-rustfmt"
               )
    end

    test "prepends preambles after codegen" do
      template = RustQ.parse!("fn answer() -> i32 { 42 }", "answer.rs")

      assert RustQ.render!(template, preamble: "// generated\n\n") ==
               "// generated\n\nfn answer() -> i32 {\n    42\n}\n"

      assert RustQ.render!("fn answer() -> i32 { 42 }", "answer.rs",
               preamble: ["// generated", "\n\n"]
             ) ==
               "// generated\n\nfn answer() -> i32 {\n    42\n}\n"
    end

    test "uses fragment wrappers" do
      code =
        """
        __rq_items!();

        pub fn run() -> i32 {
            __rq_body!();
            __rq_value!()
        }
        """
        |> RustQ.render!("fragments.rs",
          bind: [value: Rust.fragment(:expr, "answer")],
          splice: [
            items: [Rust.fragment(:item, "const answer: i32 = 42;")],
            body: [Rust.fragment(:stmt, "let answer = answer + 1;")]
          ]
        )

      assert code =~ "const answer: i32 = 42;"
      assert code =~ "let answer = answer + 1;"
      assert code =~ "answer\n}"
    end
  end

  describe "render_file" do
    alias RustQ.Rust.AST.ItemBuilder, as: I

    test "loads and renders template files" do
      path = tmp_template_path()
      File.write!(path, "pub struct __rq_Name { __rq_fields: (), }")

      code =
        path
        |> RustQ.parse_file!()
        |> RustQ.bind(Name: :User)
        |> RustQ.splice(:fields, I.field(:id, :i64, vis: :pub))
        |> RustQ.render!()

      assert code =~ "pub struct User"
      assert code =~ "pub id: i64"

      assert {:ok, rendered} =
               RustQ.render_file(path, bind: [Name: :Post], splice: [fields: I.field(:id, :i64)])

      assert rendered =~ "struct Post"
    after
      if path = Process.get(:rustq_template_path), do: File.rm(path)
    end

    test "expands relative template includes before parsing and rendering" do
      dir = tmp_template_dir()
      template = Path.join(dir, "main.rs")
      partial = Path.join(dir, "partials/fields.rs")
      nested = Path.join(dir, "partials/methods.rs")

      File.mkdir_p!(Path.dirname(partial))
      File.write!(partial, "pub id: i64,")
      File.write!(nested, "pub fn id(&self) -> i64 { self.id }")

      File.write!(template, """
      pub struct User {
          __rq_include!("partials/fields.rs");
      }

      impl User {
          __rq_include!("partials/methods.rs");
      }
      """)

      code = RustQ.render_file!(template)

      assert code =~ "pub struct User"
      assert code =~ "pub id: i64"
      assert code =~ "pub fn id(&self) -> i64"
    after
      if dir = Process.get(:rustq_template_dir), do: File.rm_rf(dir)
    end

    test "reports include cycles" do
      dir = tmp_template_dir()
      a = Path.join(dir, "a.rs")
      b = Path.join(dir, "b.rs")

      File.mkdir_p!(dir)
      File.write!(a, ~s[__rq_include!("b.rs");])
      File.write!(b, ~s[__rq_include!("a.rs");])

      assert {:error, [%{type: :include_error, message: message, include_stack: include_stack}]} =
               RustQ.render_file(a)

      assert message =~ "cyclic RustQ include"
      assert include_stack == [Path.expand(a), Path.expand(b), Path.expand(a)]
    after
      if dir = Process.get(:rustq_template_dir), do: File.rm_rf(dir)
    end

    defp tmp_template_path do
      path =
        Path.join(System.tmp_dir!(), "rustq-template-") <>
          Integer.to_string(System.unique_integer([:positive])) <> ".rs"

      Process.put(:rustq_template_path, path)
      path
    end

    defp tmp_template_dir do
      path =
        Path.join(System.tmp_dir!(), "rustq-template-dir-") <>
          Integer.to_string(System.unique_integer([:positive]))

      Process.put(:rustq_template_dir, path)
      path
    end
  end
end
