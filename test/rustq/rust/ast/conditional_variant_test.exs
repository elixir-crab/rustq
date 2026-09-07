defmodule RustQ.Rust.AST.ConditionalVariantTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.PatternBuilder, as: P

  @tag :tmp_dir
  test "named variants and match arms retain feature attributes", %{tmp_dir: dir} do
    cfg = A.attr(:cfg, feature: "extended")

    event = %AST.Enum{
      name: :Event,
      variants: [
        %AST.EnumVariant{name: :Empty},
        %AST.EnumVariant{
          name: :Value,
          fields: [%AST.StructField{name: :value, type: A.type_path(:i64)}],
          attrs: [cfg]
        }
      ]
    }

    decode = %AST.Function{
      name: :value,
      args: A.function_args(event: A.type_path(:Event)),
      returns: A.type_path(:i64),
      body: [
        A.return_stmt(
          A.match_expr(A.var(:event), [
            %AST.Arm{pattern: P.path([:Event, :Empty]), body: [A.return_stmt(0)]},
            %AST.Arm{
              pattern: P.struct([:Event, :Value], value: P.var(:value)),
              attrs: [cfg],
              body: [A.return_stmt(A.var(:value))]
            }
          ])
        )
      ]
    }

    source = Rust.render_all([event, decode])

    for {flags, input} <- [
          {[], "Event::Empty"},
          {["--cfg", ~s|feature="extended"|], "Event::Value { value: 7 }"}
        ] do
      path = Path.join(dir, "event.rs")
      binary = Path.join(dir, "event")
      File.write!(path, source <> "\nfn main() { println!(\"{}\", value(#{input})); }\n")
      assert {_, 0} = System.cmd("rustc", [path, "-o", binary] ++ flags, stderr_to_stdout: true)
      assert {output, 0} = System.cmd(binary, [])
      assert String.trim(output) == if(flags == [], do: "0", else: "7")
    end
  end
end
