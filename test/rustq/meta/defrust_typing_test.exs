defmodule RustQ.Meta.DefrustTypingTest do
  use RustQ.Test, async: true

  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Rust.AST

  test "external struct constructors use the same path as their remote types" do
    defmodule ExternalConstructorCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec position(R.u64()) :: Core.Position.t()
      defrustp(position(line), do: struct_literal(Core.Position, line: line))
    end

    function = MetaAST.function!(ExternalConstructorCase, :position)
    assert %AST.TypePath{parts: [:core, :Position]} = function.returns

    assert [%AST.Return{expr: %AST.StructLiteral{path: %AST.Path{parts: [:core, :Position]}}}] =
             function.body
  end

  test "builds a function AST from defrust valid Elixir" do
    defmodule GeneratedSaveCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec generated_save(R.ref(Canvas.t())) :: R.nif_result(R.unit())
      defrust generated_save(canvas) do
        canvas.save()
        :ok
      end
    end

    assert %AST.Function{name: :generated_save, body: [%AST.ExprStmt{}, %AST.Return{}]} =
             GeneratedSaveCase |> MetaAST.functions() |> List.first()

    source = GeneratedSaveCase.__rustq_source__()
    assert source =~ "fn generated_save(canvas: &Canvas) -> NifResult<()>"
    assert source =~ "canvas.save();"
    assert source =~ "Ok(())"
  end

  test "defrust auto-borrows fields reached through slice get unwrap" do
    defmodule AutoBorrowSliceFieldCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @type kind :: R.enum(one: [], repeated: [])
      @type field :: %{required(:kind) => kind()}

      @spec use_kind(R.ref(kind())) :: R.nif_result(R.unit())
      defrust(use_kind(_kind), do: :ok)

      @spec run(R.slice(field()), R.usize()) :: R.nif_result(R.unit())
      defrust run(fields, index) do
        field = fields.get(index).unwrap()
        use_kind(field.kind)
        :ok
      end
    end

    source = AutoBorrowSliceFieldCase.__rustq_source__()

    assert source =~ "use_kind(&field.kind)?;"
    assert RustQ.valid?(source, "auto_borrow_slice_field.rs")
  end

  test "defrust auto-borrows struct field access from expected ref types" do
    defmodule AutoBorrowStructFieldCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @type kind :: R.enum(one: [], repeated: [])
      @type field :: %{required(:kind) => kind()}

      @spec use_kind(R.ref(kind())) :: R.nif_result(R.unit())
      defrust(use_kind(_kind), do: :ok)

      @spec run(field()) :: R.nif_result(R.unit())
      defrust run(field) do
        use_kind(field.kind)
        :ok
      end
    end

    source = AutoBorrowStructFieldCase.__rustq_source__()

    assert source =~ "use_kind(&field.kind)?;"
    assert RustQ.valid?(source, "auto_borrow_struct_field.rs")
  end

  test "defrust checks closure bodies against expected callback return type" do
    defmodule AutoBorrowClosureReturnCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec with_callback(R.raw(:"fn() -> &Color")) :: R.nif_result(R.unit())
      defrust(with_callback(_callback), do: :ok)

      @spec run(R.raw(:Color)) :: R.nif_result(R.unit())
      defrust run(color) do
        with_callback(fn -> color end)
        :ok
      end
    end

    source = AutoBorrowClosureReturnCase.__rustq_source__()

    assert source =~ "with_callback(|| &color)?;"
  end

  test "defrust auto-borrows array literals for expected slices" do
    defmodule AutoBorrowArraySliceCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec use_values(R.slice(R.u32())) :: R.nif_result(R.unit())
      defrust(use_values(_values), do: :ok)

      @spec run() :: R.nif_result(R.unit())
      defrust run() do
        use_values(array([1, 2, 3]))
        :ok
      end
    end

    source = AutoBorrowArraySliceCase.__rustq_source__()

    assert source =~ "use_values(&[1, 2, 3])?;"
    assert RustQ.valid?(source, "auto_borrow_array_slice.rs")
  end

  test "defrust propagates let RHS through downstream comparisons" do
    defmodule PropagateLetComparisonCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @type field :: %{required(:id) => R.u32()}

      @spec read_id() :: R.nif_result(R.u32())
      defrust(read_id(), do: {:ok, 0})

      @spec run(R.slice(field())) :: R.nif_result(R.unit())
      defrust run(fields) do
        field_id = read_id()

        if field_id == 0 do
          :ok
        else
          case fields.binary_search_by_key(field_id, fn field -> field.id end) do
            {:ok, _index} -> :ok
            {:error, _index} -> {:error, badarg()}
          end
        end
      end
    end

    source = PropagateLetComparisonCase.__rustq_source__()

    assert source =~ "let field_id = read_id()?;"
    assert source =~ "fields.binary_search_by_key(&field_id, |field| field.id)"
    assert RustQ.valid?(source, "propagate_let_comparison.rs")
  end

  test "defrust propagates call arguments through mutable vec push" do
    defmodule PropagateMutRefVecPushCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode_value() :: R.nif_result(term())
      defrust(decode_value(), do: {:ok, make_term()})

      @spec make_term() :: term()
      defrust(make_term(), do: 0)

      @spec run(R.mut_ref(R.vec(term()))) :: R.nif_result(R.unit())
      defrust run(values) do
        values.push(decode_value())
        :ok
      end
    end

    source = PropagateMutRefVecPushCase.__rustq_source__()

    assert source =~ "values.push(decode_value()?);"
    assert RustQ.valid?(source, "propagate_mut_ref_vec_push.rs")
  end

  test "defrust auto-borrows configured generated static items" do
    defmodule AutoBorrowConfiguredStaticCase do
      use RustQ.Meta, static_types: [GUID_ATOM: RustQ.Type.raw(:"OnceLock<Atom>")]
      alias RustQ.Type, as: R

      @spec cached_atom(R.ref(R.raw(:"OnceLock<Atom>"))) :: R.nif_result(R.unit())
      defrust(cached_atom(_cell), do: :ok)

      @spec run() :: R.nif_result(R.unit())
      defrust run() do
        cached_atom(GUID_ATOM)
        :ok
      end
    end

    source = AutoBorrowConfiguredStaticCase.__rustq_source__()

    assert source =~ "cached_atom(&GUID_ATOM)?;"
  end

  test "defrust auto-borrows external static items from rust source metadata" do
    defmodule AutoBorrowExternalStaticCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/external_statics.rs"]
      alias RustQ.Type, as: R

      @spec cached_atom(R.ref(R.raw(:"OnceLock<Atom>"))) :: R.nif_result(R.unit())
      defrust(cached_atom(_cell), do: :ok)

      @spec run() :: R.nif_result(R.unit())
      defrust run() do
        cached_atom(GUID_ATOM)
        :ok
      end
    end

    source = AutoBorrowExternalStaticCase.__rustq_source__()

    assert source =~ "cached_atom(&GUID_ATOM)?;"
  end

  test "defrust checks with bodies against expected call argument type" do
    defmodule AutoBorrowWithBodyCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec maybe_color(R.bool(), R.raw(:Color)) :: R.nif_result(R.raw(:Color))
      defrust maybe_color(flag, color) do
        if flag do
          {:ok, color}
        else
          {:error, badarg()}
        end
      end

      @spec use_color(R.ref(R.raw(:Color))) :: R.nif_result(R.unit())
      defrust(use_color(_color), do: :ok)

      @spec run(R.raw(:Color), R.bool()) :: R.nif_result(R.unit())
      defrust run(color, flag) do
        use_color(
          case maybe_color(flag, color) do
            {:ok, value} -> value
            _reason -> color
          end
        )

        :ok
      end
    end

    source = AutoBorrowWithBodyCase.__rustq_source__()

    assert source =~ "Ok(value) => &value"
    assert source =~ "_reason => &color"
    assert RustQ.valid?(source, "auto_borrow_with_body.rs")
  end

  test "defrust checks for reduce arms against expected accumulator type" do
    defmodule AutoBorrowForReduceCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec use_color(R.ref(R.raw(:Color))) :: R.nif_result(R.unit())
      defrust(use_color(_color), do: :ok)

      @spec run(R.raw(:Color), R.vec(R.bool())) :: R.nif_result(R.unit())
      defrust run(color, flags) do
        use_color(
          for flag <- flags, reduce: color do
            acc ->
              if flag do
                acc
              else
                acc
              end
          end
        )

        :ok
      end
    end

    source = AutoBorrowForReduceCase.__rustq_source__()

    assert source =~ "let mut __rustq_reduce = &color;"
    assert source =~ "if flag { acc } else { acc }"
    assert RustQ.valid?(source, "auto_borrow_for_reduce.rs")
  end

  test "defrust checks if branches against expected call argument type" do
    defmodule AutoBorrowIfBranchCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec use_color(R.ref(R.raw(:Color))) :: R.nif_result(R.unit())
      defrust(use_color(_color), do: :ok)

      @spec run(R.raw(:Color), R.bool()) :: R.nif_result(R.unit())
      defrust run(color, flag) do
        use_color(
          if flag do
            color
          else
            color
          end
        )

        :ok
      end
    end

    source = AutoBorrowIfBranchCase.__rustq_source__()

    assert source =~ "if flag { &color } else { &color }"

    assert RustQ.valid?(source, "auto_borrow_if_branch.rs")
  end

  test "defrust checks case arms against expected call argument type" do
    defmodule AutoBorrowCaseArmCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec use_color(R.ref(R.raw(:Color))) :: R.nif_result(R.unit())
      defrust(use_color(_color), do: :ok)

      @spec run(R.raw(:Color), R.u32()) :: R.nif_result(R.unit())
      defrust run(color, flag) do
        use_color(
          case flag do
            0 -> color
            1 -> color
          end
        )

        :ok
      end
    end

    source = AutoBorrowCaseArmCase.__rustq_source__()

    assert source =~ "0 => &color"
    assert source =~ "1 => &color"
    assert RustQ.valid?(source, "auto_borrow_case_arm.rs")
  end

  test "defrust auto-borrows call arguments from expected ref types" do
    defmodule AutoBorrowCallArgumentCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec use_color(R.ref(R.raw(:Color))) :: R.nif_result(R.unit())
      defrust(use_color(_color), do: :ok)

      @spec mutate_color(R.mut_ref(R.raw(:Color))) :: R.nif_result(R.unit())
      defrust(mutate_color(_color), do: :ok)

      @spec run(R.raw(:Color)) :: R.nif_result(R.unit())
      defrust run(color) do
        use_color(color)
        mutate_color(color)
        :ok
      end
    end

    source = AutoBorrowCallArgumentCase.__rustq_source__()

    assert source =~ "use_color(&color)?;"
    assert source =~ "mutate_color(&mut color)?;"
    assert RustQ.valid?(source, "auto_borrow_call_argument.rs")
  end

  test "defrust specs can use explicit Rust path and raw type markers" do
    defmodule ExplicitRustTypeCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec draw_oval_impl(
              R.ref(SkiaSafe.Canvas.t()),
              GeneratedOpts.OvalOpts.t(R.lifetime(:a)),
              R.slice({R.atom(), R.term()})
            ) :: R.nif_result(R.unit())
      defrust draw_oval_impl(canvas, opts, raw_opts) do
        rect = Rect.from_xywh(opts.x, opts.y, opts.width, opts.height)
        canvas.draw_oval(rect, ref(raw_opts))
        :ok
      end
    end

    source = ExplicitRustTypeCase.__rustq_source__()
    assert source =~ "fn draw_oval_impl<'a>("
    assert source =~ "canvas: &skia_safe::Canvas"
    assert source =~ "opts: generated_opts::OvalOpts<'a>"
    assert source =~ "raw_opts: &[(Atom, Term<'a>)]"
  end

  test "defrust infers mutable option pattern bindings from mut_ref usage" do
    defmodule MutableOptionPatternCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec apply_if_present(R.option(Paint.t())) :: R.nif_result(R.unit())
      defrust apply_if_present(maybe_paint) do
        case maybe_paint do
          {:some, paint} ->
            unwrap!(apply_blend_mode(mut_ref(paint), []))
            use_paint(ref(paint))

          :none ->
            :ok
        end

        :ok
      end
    end

    source = MutableOptionPatternCase.__rustq_source__()
    assert source =~ "if let Some(mut paint) = maybe_paint"
    assert source =~ "apply_blend_mode(&mut paint"
  end

  test "defrust infers mutable let bindings from statement method calls" do
    defmodule MutableMethodReceiverCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec build() :: R.nif_result(R.unit())
      defrust build() do
        builder = PathBuilder.new()
        builder.add_circle(Point.new(0.0, 0.0), 1.0, none())
        use_path(builder.detach())

        :ok
      end
    end

    source = MutableMethodReceiverCase.__rustq_source__()
    assert source =~ "let mut builder = PathBuilder::new();"
    assert source =~ "builder.add_circle(Point::new(0.0, 0.0), 1.0, None);"
  end
end
