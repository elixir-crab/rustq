defmodule RustQ.Reach.Smells.RawRustEscapeTest do
  use RustQ.Test.ReachSmellCase, async: true

  alias RustQ.Reach.Smells.RawRustEscape

  test "detects large raw Rust escapes" do
    source = ~S'''
    defmodule Sample.RawEscape do
      def build do
        RustQ.Rust.fragment(:item, """
        fn generated() {
            do_work();
        }
        """)
      end
    end
    '''

    assert [%{kind: :rustq_large_raw_rust_escape}] = run_check(RawRustEscape, source)
  end

  test "ignores tiny raw Rust escapes" do
    source = """
    defmodule Sample.TinyRawEscape do
      def build do
        RustQ.Rust.AST.Builder.macro_item("rustler::atoms! { ok }")
      end
    end
    """

    assert [] = run_check(RawRustEscape, source)
  end
end
