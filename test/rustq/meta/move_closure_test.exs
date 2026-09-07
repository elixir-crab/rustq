defmodule RustQ.Meta.MoveClosureTest do
  use RustQ.Test, async: true

  alias RustQ.Rust.AST.Builder, as: A

  defmodule Callback do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec callback(String.t()) ::
            R.impl((-> R.usize()), traits: [Send.t()], lifetime: R.lifetime(:static))
    defrust callback(label) do
      move(fn -> label.len() end)
    end

    @spec pair_callback(integer()) :: R.impl(({integer(), integer()} -> integer()))
    defrust pair_callback(offset) do
      move(fn {left, right} -> left + right + offset end)
    end

    @spec borrowed(String.t()) :: R.raw(:usize)
    defrust borrowed(label) do
      invoke(fn -> label.len() end)
    end
  end

  @tag :tmp_dir
  test "move callbacks own captures after the factory returns", %{tmp_dir: tmp_dir} do
    source = rust_source!(Callback)
    assert source =~ "move || label.len()"
    assert source =~ "invoke(|| label.len())"

    path = Path.join(tmp_dir, "callback.rs")
    executable = Path.join(tmp_dir, "callback")

    File.write!(
      path,
      source <>
        typed_handler_source() <>
        """

        fn invoke(f: impl Fn() -> usize) -> usize { f() }
        fn main() {
            let callback = callback(String::from("slider"));
            let length = std::thread::spawn(callback).join().unwrap();
            assert_eq!(length, 6);
            assert_eq!(pair_callback(4)((2, 3)), 9);
            let handler = typed_handler();
            assert_eq!(handler(&7), 7);
            assert_eq!(borrowed(String::from("value")), 5);
        }
        """
    )

    assert {_, 0} =
             System.cmd("rustc", ["--edition=2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"", 0} = System.cmd(executable, [])
  end

  defp typed_handler_source do
    alias RustQ.Rust.AST
    arg = {%AST.PatVar{name: :event}, %AST.TypeRef{inner: A.type_path(:i64)}}
    callback = A.closure([arg], %AST.UnaryOp{op: :deref, expr: A.var(:event)}, move: true)

    type = %AST.TypeImplTrait{
      callable: %AST.TypeBareFn{
        args: [%AST.TypeRef{inner: A.type_path(:i64)}],
        returns: A.type_path(:i64)
      }
    }

    RustQ.Rust.to_fragment(%AST.Function{
      name: :typed_handler,
      returns: type,
      body: [%AST.Return{expr: callback}]
    })
  end

  test "callable kinds and constraints remain structural" do
    alias RustQ.Meta.Type
    alias RustQ.Rust.AST

    for {kind, rust} <- [fn: "Fn", fn_mut: "FnMut", fn_once: "FnOnce"] do
      quoted = quote do: R.impl((integer() -> integer()), kind: unquote(kind))
      type = Type.parse(quoted, %{})
      assert %AST.TypeImplTrait{callable: %AST.TypeBareFn{}, kind: ^kind} = type.ast
      assert RustQ.Rust.to_fragment(%AST.TypeAlias{name: :Callback, type: type.ast}) =~ rust
    end

    assert_raise ArgumentError, ~r/callable kind/, fn ->
      Type.parse(quote(do: R.impl((-> integer()), kind: :invalid)), %{})
    end

    assert_raise ArgumentError, ~r/function type/, fn ->
      Type.parse(quote(do: R.impl(integer())), %{})
    end

    assert_raise ArgumentError, ~r/R.lifetime/, fn ->
      Type.parse(quote(do: R.impl((-> integer()), lifetime: :static)), %{})
    end
  end

  test "impl options reject duplicates and malformed traits" do
    alias RustQ.Meta.Type

    assert_raise ArgumentError, ~r/unique/, fn ->
      Type.parse(quote(do: R.impl((-> integer()), kind: :fn, kind: :fn_once)), %{})
    end

    assert_raise ArgumentError, ~r/traits must be a list/, fn ->
      Type.parse(quote(do: R.impl((-> integer()), traits: Send.t())), %{})
    end
  end

  test "AST builder defaults to borrowing and supports explicit move capture" do
    assert A.closure([], A.lit(1)).move == false
    assert A.closure([], A.lit(1), move: true).move == true
  end
end
