defmodule RustQ.Meta.DefrustTest do
  use RustQ.Test, async: true

  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Meta.GeneratedCase, as: Generated

  describe "compiled defrust fixtures" do
    test "renders a focused function exactly" do
      assert rust_source!(Generated, :draw_save) == """
             fn draw_save(canvas: &Canvas) -> NifResult<()> {
                 canvas.save();
                 Ok(())
             }
             """
    end

    test "renders atom matching and errors" do
      source = rust_source!(Generated, :decode_mode)

      assert source =~ "fn decode_mode(atom: Atom) -> NifResult<Mode>"
      assert source =~ "value if value == atoms::src_over() =>"
      assert source =~ "Ok(BlendMode::SrcOver)"
      assert source =~ ~s|Err(rustler::Error::RaiseAtom("invalid_blend_mode"))|
    end

    test "renders inferred lifetimes, propagation, and borrowing" do
      source = rust_source!(Generated, :draw_rect)

      assert source =~ "fn draw_rect<'a>("
      assert source =~ "opts: RectOpts<'a>"
      assert source =~ "raw_opts: Term<'a>"
      assert source =~ "let rect = Rect::from_xywh(opts.x, opts.y, opts.width, opts.height);"
      assert source =~ "let mut paint = decode_paint(opts.fill)?;"
      assert source =~ "apply_blend_mode(&mut paint, raw_opts)?;"
      assert source =~ "canvas.draw_rect(&rect, &paint);"
    end

    test "renders option matching" do
      source = rust_source!(Generated, :maybe_save)

      assert source =~ "fn maybe_save(canvas: Option<&Canvas>)"
      assert source =~ "None => {}"
      assert source =~ "Some(canvas) => {"
    end

    test "renders result matching" do
      source = rust_source!(Generated, :unwrap_code)

      assert source =~ "fn unwrap_code(result: Result<u32, Atom>)"
      assert source =~ "Ok(value) =>"
      assert source =~ "Err(reason) =>"
    end

    test "renders structural event patterns" do
      source = rust_source!(Generated, :handle_event)

      assert source =~ "Event::Click(Click { name: name }) =>"
      assert source =~ "Event::Resize(Resize { width: width, height: height }) =>"
    end

    test "renders a syntactically valid generated module" do
      assert RustQ.valid?(rust_source!(Generated), "generated_case.rs")
    end
  end

  test "defnif marks public entrypoints and defrustp keeps helpers private" do
    defmodule EntrypointCase do
      use RustQ.Meta

      @spec add(integer(), integer()) :: integer()
      defnif(add(left, right), do: add_impl(left, right))

      @spec add_impl(integer(), integer()) :: integer()
      defrustp(add_impl(left, right), do: left + right)

      @nif schedule: :dirty_cpu
      @spec slow_add(integer(), integer()) :: integer()
      defnif(slow_add(left, right), do: left + right)
    end

    assert nif_exported?(EntrypointCase, :add, 2)
    assert rust_source!(EntrypointCase, :add) =~ "fn add(left: i64, right: i64) -> i64"
    assert rust_source!(EntrypointCase, :slow_add) =~ ~s|#[rustler::nif(schedule = "DirtyCpu")]|
    assert rust_source!(EntrypointCase, :add_impl) =~ "fn add_impl(left: i64, right: i64) -> i64"
    refute function_exported?(EntrypointCase, :add_impl, 2)

    assert_raise ErlangError, fn -> EntrypointCase.add(1, 2) end
  end

  test "defrustimpl groups Rusty-Elixir methods with typed receivers" do
    defmodule ImplCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defrustimpl Counter, vis: :crate do
        @spec value(R.ref(R.path(:Counter))) :: R.i64()
        defrust(value(self), do: self.value)

        @spec increment(R.mut_ref(R.path(:Counter)), R.i64()) :: R.i64()
        defrust(increment(self, amount), do: self.value + amount)
      end
    end

    source = rust_source!(ImplCase)

    assert source =~ "impl Counter {"
    assert source =~ "pub(crate) fn value(&self) -> i64"
    assert source =~ "pub(crate) fn increment(&mut self, amount: i64)"
    assert source =~ "self.value + amount"
    assert RustQ.valid?(source, "defrustimpl.rs")
  end

  test "defrustimpl supports trait implementations" do
    defmodule TraitImplCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defrustimpl Displayable, for: Counter do
        @spec display(R.ref(R.path(:Counter))) :: R.str()
        defrust(display(self), do: self.label.as_str())
      end
    end

    assert rust_source!(TraitImplCase) =~ "impl Displayable for Counter {"
  end

  test "defrustimpl requires a typed reference receiver" do
    assert_raise ArgumentError,
                 ~r/first defrustimpl argument must have type R.ref.*or R.mut_ref/,
                 fn ->
                   defmodule InvalidImplReceiverCase do
                     use RustQ.Meta
                     alias RustQ.Type, as: R

                     defrustimpl Counter do
                       @spec value(R.path(:Counter)) :: R.i64()
                       defrust(value(self), do: self.value)
                     end
                   end
                 end
  end

  test "defrust combines multiple clauses, head patterns, guards, and recursion" do
    defmodule MultiClauseCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec factorial(R.i64()) :: R.i64()
      defrust(factorial(0), do: 1)
      defrust(factorial(value), do: value * factorial(value - 1))

      @spec sign(R.i64()) :: R.i64()
      defrust(sign(value) when value > 0, do: 1)
      defrust(sign(0), do: 0)
      defrust(sign(_value), do: -1)
    end

    factorial = rust_source!(MultiClauseCase, :factorial)
    sign = rust_source!(MultiClauseCase, :sign)

    assert factorial =~ "fn factorial(arg1: i64) -> i64"
    assert factorial =~ "match arg1"
    assert factorial =~ "0 => 1"
    assert factorial =~ "value => value * factorial(value - 1)"
    assert sign =~ "value if value > 0 => 1"
    assert sign =~ "_value => -1"
    assert RustQ.valid?(rust_source!(MultiClauseCase), "multi_clause_case.rs")
  end

  test "preserves no-parentheses function pointer field access in expected positions" do
    defmodule FunctionPointerFieldCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/function_pointer_field.rs"]
      alias RustQ.Type, as: R

      @spec decode_function(R.path(:DecodeField)) :: R.path(:DecodeFn)
      defrust(decode_function(field), do: field.decode)
    end

    source = FunctionPointerFieldCase.__rustq_source__()

    assert source =~ "fn decode_function(field: DecodeField) -> DecodeFn"
    assert source =~ "field.decode"
    refute source =~ "field.decode::<DecodeFn>()"
  end

  test "selects map-backed type structs with boundary derives" do
    code =
      "__rq_items!();"
      |> RustQ.render!("type_structs.rs",
        splice: [
          items:
            MetaAST.struct_type_items(Generated, [:rect_opts],
              derive: [:Clone, :Debug, "rustler::NifMap"],
              field_vis: nil
            )
        ]
      )

    assert code =~ "#[derive(Clone, Debug, rustler::NifMap)]"
    assert code =~ "pub struct RectOpts"
    assert code =~ "width: f32"
    refute code =~ "pub width: f32"
    refute code =~ "fn decode_rect_opts"
  end

  test "propagates nested result tuple binding types into conditions" do
    defmodule ResultTupleBindingCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec enabled(term()) :: R.nif_result(R.u32())
      defrust enabled(term) do
        case decode_as(term, {atom(), R.vec(R.f64()), R.bool()}) do
          {:ok, {_tag, _values, flag}} ->
            flag =
              if flag do
                1
              else
                0
              end

            {:ok, flag}

          {:error, _reason} ->
            {:ok, 0}
        end
      end
    end

    source = ResultTupleBindingCase.__rustq_source__()

    assert source =~ "if flag {"
    refute source =~ "if flag? {"
  end

  test "defrust lowers macro-generated case clauses" do
    defmodule MacroGeneratedCaseClauseCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defmacro generated_case(value) do
        clauses =
          quote do
            1 -> {:ok, 10}
            other -> {:ok, other}
          end

        quote do
          case unquote(value) do
            (unquote_splicing(clauses))
          end
        end
      end

      @spec decode(R.i64()) :: R.nif_result(R.i64())
      defrust decode(value) do
        generated_case(value)
      end
    end

    source = MacroGeneratedCaseClauseCase.__rustq_source__()

    assert source =~ "match value"
    assert source =~ "1 => Ok(10)"
    assert source =~ "other => Ok(other)"
    assert RustQ.valid?(source, "macro_generated_case_clause.rs")
  end
end
