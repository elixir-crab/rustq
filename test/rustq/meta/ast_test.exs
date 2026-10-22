defmodule RustQ.Meta.ASTTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Rust
  alias RustQ.Rust.AST.TypeBuilder, as: T

  test "quoted accepts explicit Rust AST types" do
    function =
      MetaAST.quoted(:draw_translate_impl,
        args: [
          canvas: T.ref([:skia_safe, :Canvas]),
          opts: T.path([:generated_opts, :TranslateOpts], lifetimes: [:a]),
          _raw_opts: "&[(Atom, Term<'a>)]"
        ],
        returns: T.nif_result(T.unit()),
        do:
          quote do
            canvas.translate({opts.x, opts.y})
            :ok
          end
      )

    source = Rust.render(function)

    assert source =~ "fn draw_translate_impl<'a>("
    assert source =~ "canvas: &skia_safe::Canvas"
    assert source =~ "opts: generated_opts::TranslateOpts<'a>"
    assert source =~ "_raw_opts: &[(Atom, Term<'a>)]"
    assert source =~ "canvas.translate((opts.x, opts.y));"
    assert source =~ "Ok(())"
  end

  test "quoted maps configured Rust module alias calls" do
    function =
      MetaAST.quoted(:atom_call,
        args: [],
        returns: quote(do: RustQ.Type.nif_result(atom())),
        rust_modules: %{[:Atoms] => [:atoms]},
        do:
          quote do
            Atoms.fill()
          end
      )

    source = Rust.render(function)
    assert source =~ "atoms::fill()"
  end
end
