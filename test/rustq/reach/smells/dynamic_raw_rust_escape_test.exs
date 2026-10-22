defmodule RustQ.Reach.Smells.DynamicRawRustEscapeTest do
  use RustQ.Test.ReachSmellCase, async: true

  alias RustQ.Reach.Smells.DynamicRawRustEscape

  test "detects dynamic raw Rust escapes" do
    source = """
    defmodule Sample.DynamicRawEscape do
      def build(source), do: raw_expr!(source)
    end
    """

    assert [%{kind: :rustq_dynamic_raw_rust_escape}] = run_check(DynamicRawRustEscape, source)
  end

  test "allows literal raw Rust escapes" do
    source = """
    defmodule Sample.LiteralRawEscape do
      def build, do: raw_expr!(\"unsafe { value }\")
    end
    """

    assert [] = run_check(DynamicRawRustEscape, source)
  end

  test "distinguishes structural expression normalization from raw AST escapes" do
    structural = """
    defmodule Sample.StructuralExpression do
      def build(expression), do: RustQ.Rust.AST.Builder.expr(expression)
    end
    """

    raw = """
    defmodule Sample.DynamicASTEscape do
      def build(source), do: RustQ.Rust.AST.Builder.escape_expr(source)
    end
    """

    assert [] = run_check(DynamicRawRustEscape, structural)
    assert [%{kind: :rustq_dynamic_raw_rust_escape}] = run_check(DynamicRawRustEscape, raw)
  end
end
