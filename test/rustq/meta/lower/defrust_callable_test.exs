defmodule RustQ.Meta.Lower.DefrustCallableTest do
  use RustQ.Test, async: true

  alias RustQ.Diagnostic

  test "defrust uses module specs as callable metadata for propagation inference" do
    defmodule LocalCallablePropagationCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode(atom()) :: R.nif_result(R.u32())
      defrust decode(atom) do
        case atom do
          :ok -> {:ok, 1}
          _ -> {:error, :badarg}
        end
      end

      @spec consume(R.u32()) :: R.nif_result(R.unit())
      defrust consume(value) do
        _copy = value
        :ok
      end

      @spec argument(atom()) :: R.nif_result(R.unit())
      defrust argument(atom) do
        consume(decode(atom))
        :ok
      end
    end

    source = LocalCallablePropagationCase.__rustq_source__()

    assert source =~ "consume(decode(atom)?)"
    assert RustQ.valid?(source, "local_callable_propagation.rs")
  end

  test "defrust uses rust source method metadata for discarded fallible statements" do
    defmodule RustSourceMethodPropagationCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/decoder_metadata.rs"]
      alias RustQ.Type, as: R

      @spec skip(R.mut_ref(R.path(:Decoder, R.lifetime(:_)))) :: R.nif_result(R.unit())
      defrust skip(decoder) do
        decoder.read_var_int64()
        :ok
      end
    end

    source = RustSourceMethodPropagationCase.__rustq_source__()

    assert source =~ "decoder.read_var_int64()?;"
    assert source =~ "Ok(())"
    assert RustQ.valid?(source, "rust_source_method_propagation.rs")
  end

  defmodule SynSourceDomain do
    defmacro __using__(_opts) do
      quote do
        use RustQ.Meta, rust_sources: ["test/fixtures/external_callables.rs"]
      end
    end
  end

  test "defrust lowers case when guards" do
    defmodule CaseWhenGuardCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode(term()) :: R.nif_result(R.u32())
      defrust decode(term) do
        case decode_as(term, {atom(), R.u32()}) do
          {:ok, {tag, value}} when tag == Atoms.count() and value > 0 -> {:ok, value}
          {:ok, {_tag, _value}} -> {:error, badarg()}
          {:error, _reason} -> {:error, badarg()}
        end
      end
    end

    source = CaseWhenGuardCase.__rustq_source__()

    assert source =~ "Ok((tag, value)) if tag == atoms::count() && value > 0 =>"
    assert source =~ "Ok(value)"
    assert RustQ.valid?(source, "case_when_guard_case.rs")
  end

  test "defrust lowers with expressions for result-oriented alternatives" do
    defmodule WithResultCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode_color(R.u32()) :: R.nif_result(R.u32())
      defrust decode_color(term) do
        case term do
          1 -> {:ok, 10}
          _ -> {:error, badarg()}
        end
      end

      @spec decode_shader(R.u32()) :: R.nif_result(R.u32())
      defrust decode_shader(term) do
        case term do
          2 -> {:ok, 20}
          _ -> {:error, badarg()}
        end
      end

      @spec decode(R.u32()) :: R.nif_result(R.u32())
      defrust decode(term) do
        with {:error, _color_reason} <- decode_color(term),
             {:error, _shader_reason} <- decode_shader(term) do
          {:error, badarg()}
        else
          {:ok, value} -> {:ok, value + 1}
          {:error, _reason} -> {:error, badarg()}
        end
      end
    end

    source = WithResultCase.__rustq_source__()

    assert source =~ "match decode_color(term)"
    assert source =~ "Err(_color_reason) =>"
    assert source =~ "match __rustq_with_value"
    assert source =~ "Ok(value) =>"
    assert source =~ "Ok(value + 1)"
    refute source =~ "return "
    assert RustQ.valid?(source, "with_result_case.rs")
  end

  test "defrust lowers for reduce as an expression-valued fallible loop" do
    defmodule ForReduceResultCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec validate(R.vec(R.u32())) :: R.nif_result(R.unit())
      defrust validate(values) do
        for value <- values, reduce: :ok do
          :ok ->
            if value == 0 do
              {:error, badarg()}
            else
              :ok
            end
        end
      end
    end

    source = ForReduceResultCase.__rustq_source__()

    assert source =~ "let mut __rustq_reduce = Ok(());"
    assert source =~ "for value in values"
    assert source =~ "__rustq_reduce = match __rustq_reduce"
    assert source =~ "Ok(()) =>"
    assert source =~ "__rustq_reduce_value =>"
    assert source =~ "Err(rustler::Error::BadArg)"
    refute source =~ "return "
    assert RustQ.valid?(source, "for_reduce_result_case.rs")
  end

  test "defrust can use Syn-derived external callable metadata" do
    defmodule SynExternalCallableCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/external_callables.rs"]

      alias RustQ.Type, as: R

      @spec decode_color(R.term()) :: R.nif_result(R.path(:Color))
      defrust decode_color(term) do
        color = decode_as!(term, R.u32())
        {:ok, Color.from_argb(255, 0, 0, color)}
      end

      @spec draw(R.term(), R.slice({R.atom(), R.term()})) :: R.nif_result(R.unit())
      defrust draw(term, opts) do
        unwrap!(stroke_paint(decode_color(term), 1.0, opts))
        :ok
      end
    end

    source = SynExternalCallableCase.__rustq_source__()

    assert source =~ "stroke_paint(decode_color(term)?, 1.0, opts)?;"
    assert RustQ.valid?(source, "syn_external_callable.rs")
  end

  test "defrust infers propagation through parent-module Rust calls" do
    defmodule SynParentCallableCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/external_callables.rs"]

      alias RustQ.Type, as: R

      @spec decode_color(R.term()) :: R.nif_result(R.path(:Color))
      defrust decode_color(term) do
        color = decode_as!(term, R.u32())
        {:ok, Color.from_argb(255, 0, 0, color)}
      end

      @spec draw(R.term(), R.slice({R.atom(), R.term()})) :: R.nif_result(R.path(:Paint))
      defrust draw(term, opts) do
        Super.stroke_paint(decode_color(term), 1.0, opts)
      end
    end

    source = SynParentCallableCase.__rustq_source__()

    assert source =~ "super::stroke_paint(decode_color(term)?, 1.0, opts)"
    assert RustQ.valid?(source, "syn_parent_callable.rs")
  end

  test "defrust can use Syn-derived external method metadata" do
    defmodule SynExternalMethodCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/external_methods.rs"]

      alias RustQ.Type, as: R

      @spec decode_blend_mode(R.atom()) :: R.nif_result(R.path(:BlendMode))
      defrust decode_blend_mode(atom) do
        case atom do
          :src_over -> {:ok, BlendMode.SrcOver}
          _ -> {:error, :badarg}
        end
      end

      @spec apply(R.mut_ref(Paint.t()), R.atom()) :: R.nif_result(R.unit())
      defrust apply(paint, atom) do
        paint.set_blend_mode(decode_blend_mode(atom))
        :ok
      end
    end

    source = SynExternalMethodCase.__rustq_source__()

    assert source =~ "paint.set_blend_mode(decode_blend_mode(atom)?);"
    assert RustQ.valid?(source, "syn_external_method.rs")
  end

  test "__rustq_callables__ exports local specs without duplicating external metadata" do
    defmodule ExternalMetadataExportCase do
      use RustQ.Meta, rust_sources: ["test/fixtures/external_callables.rs"]

      alias RustQ.Type, as: R

      @spec decode_color(R.term()) :: R.nif_result(R.path(:Color))
      defrust decode_color(term) do
        color = decode_as!(term, R.u32())
        {:ok, Color.from_argb(255, 0, 0, color)}
      end
    end

    names = Enum.map(ExternalMetadataExportCase.__rustq_callables__(), & &1.name)

    assert "decode_color" in names
    refute "stroke_paint" in names
  end

  test "defrust can use callable metadata from other RustQ modules" do
    defmodule CallableProducerCase do
      use RustQ.Meta

      alias RustQ.Type, as: R

      @spec decode_color(R.term()) :: R.nif_result(R.path(:Color))
      defrust decode_color(term) do
        color = decode_as!(term, R.u32())
        {:ok, Color.from_argb(255, 0, 0, color)}
      end
    end

    defmodule CallableConsumerCase do
      use RustQ.Meta,
        rust_sources: ["test/fixtures/external_callables.rs"],
        callable_modules: [CallableProducerCase]

      alias RustQ.Type, as: R

      @spec draw(R.term(), R.slice({R.atom(), R.term()})) :: R.nif_result(R.unit())
      defrust draw(term, opts) do
        unwrap!(stroke_paint(decode_color(term), 1.0, opts))
        :ok
      end
    end

    source = CallableConsumerCase.__rustq_source__()

    assert source =~ "stroke_paint(decode_color(term)?, 1.0, opts)?;"
    assert RustQ.valid?(source, "module_callable_consumer.rs")
  end

  test "defrust can use Syn-derived external callable metadata through wrapper macros" do
    defmodule SynExternalCallableWrapperCase do
      use SynSourceDomain

      alias RustQ.Type, as: R

      @spec decode_color(R.term()) :: R.nif_result(R.path(:Color))
      defrust decode_color(term) do
        color = decode_as!(term, R.u32())
        {:ok, Color.from_argb(255, 0, 0, color)}
      end

      @spec draw(R.term(), R.slice({R.atom(), R.term()})) :: R.nif_result(R.unit())
      defrust draw(term, opts) do
        unwrap!(stroke_paint(decode_color(term), 1.0, opts))
        :ok
      end
    end

    source = SynExternalCallableWrapperCase.__rustq_source__()

    assert source =~ "stroke_paint(decode_color(term)?, 1.0, opts)?;"
    assert RustQ.valid?(source, "syn_external_callable_wrapper.rs")
  end

  test "unknown RustQ.Meta options raise structured diagnostics" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule UnknownMetaOptionCase do
          use RustQ.Meta, rust_source: "test/fixtures/external_callables.rs"
        end
      end

    assert %Diagnostic{phase: :defrust, kind: :invalid_meta_option} = error.diagnostic
    assert error.diagnostic.details.key == :rust_source
  end

  test "malformed RustQ.Meta callable metadata options raise structured diagnostics" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule MalformedMetaOptionCase do
          use RustQ.Meta, rust_packages: [123]
        end
      end

    assert %Diagnostic{phase: :defrust, kind: :invalid_meta_option} = error.diagnostic
    assert error.diagnostic.details.key == :rust_packages
  end

  test "rust_sources given as an expression must evaluate to paths" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule ComputedMetaOptionCase do
          @sources [:not_a_path]
          use RustQ.Meta, rust_sources: @sources
        end
      end

    assert %Diagnostic{phase: :defrust, kind: :invalid_meta_option} = error.diagnostic
    assert error.diagnostic.details.key == :rust_sources
  end

  test "Rust source callable metadata preserves cross-file public aliases" do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "rustq_source_aliases_#{unique}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    paint_path = Path.join(dir, "paint.rs")
    core_path = Path.join(dir, "core.rs")
    generated_path = Path.join(dir, "generated.rs")

    File.write!(paint_path, """
    pub use sb::SkPaint_Cap as Cap;

    impl Paint {
      pub fn set_stroke_cap(&mut self, cap: Cap) -> &mut Self { self }
    }
    """)

    File.write!(core_path, "pub use paint::Cap as PaintCap;\n")
    File.write!(generated_path, "fn decode(atom: Atom) -> NifResult<PaintCap> { todo!() }\n")

    module = Module.concat(__MODULE__, :CrossFileRustSourceAliasesCase)

    Module.create(
      module,
      quote do
        use RustQ.Meta,
          rust_sources: unquote(Macro.escape([paint_path, core_path, generated_path]))

        alias RustQ.Type, as: R

        @spec run(R.mut_ref(Paint.t()), R.atom()) :: R.nif_result(R.unit())
        defrust run(paint, atom) do
          paint.set_stroke_cap(decode(atom))
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    assert module.__rustq_source__() =~ "paint.set_stroke_cap(decode(atom)?);"
  end

  test "infers propagation through source-backed From impl into Into argument" do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "rustq_from_into_#{unique}.rs")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, """
    struct Color;
    struct Color4f;
    struct ImageFilter;

    impl From<Color> for Color4f {
      fn from(color: Color) -> Self { todo!() }
    }

    fn drop_shadow(color: impl Into<Color4f>) -> Option<ImageFilter> { todo!() }
    """)

    module = Module.concat(__MODULE__, :FromIntoArgumentCase)

    Module.create(
      module,
      quote do
        use RustQ.Meta, rust_sources: [unquote(path)]
        alias RustQ.Type, as: R

        @spec decode_color(term()) :: R.nif_result(R.path(:Color))
        defrust decode_color(term) do
          _value = decode_as!(term, R.u32())
          {:ok, Color.default()}
        end

        @spec run(term()) :: R.nif_result(R.unit())
        defrust run(term) do
          drop_shadow(decode_color(term))
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    assert module.__rustq_source__() =~ "drop_shadow(decode_color(term)?);"
  end

  test "Rust source callable cache refreshes when the source file changes" do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "rustq_source_cache_#{unique}.rs")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "fn consume_first(color: Color) -> NifResult<()> { todo!() }\n")

    first_module = Module.concat(__MODULE__, :FreshRustSourceFirst)

    Module.create(
      first_module,
      quote do
        use RustQ.Meta, rust_sources: [unquote(path)]
        alias RustQ.Type, as: R

        @spec decode(atom()) :: R.nif_result(R.path(:Color))
        defrust decode(atom) do
          color = decode_as!(atom, R.u32())
          {:ok, Color.from_argb(255, color, 0, 0)}
        end

        @spec run(atom()) :: R.nif_result(R.unit())
        defrust run(atom) do
          consume_first(decode(atom))
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    assert first_module.__rustq_source__() =~ "consume_first(decode(atom)?)?;"

    File.write!(path, "fn consume_second(color: Color) -> NifResult<()> { todo!() }\n")

    second_module = Module.concat(__MODULE__, :FreshRustSourceSecond)

    Module.create(
      second_module,
      quote do
        use RustQ.Meta, rust_sources: [unquote(path)]
        alias RustQ.Type, as: R

        @spec decode(atom()) :: R.nif_result(R.path(:Color))
        defrust decode(atom) do
          color = decode_as!(atom, R.u32())
          {:ok, Color.from_argb(255, color, 0, 0)}
        end

        @spec run(atom()) :: R.nif_result(R.unit())
        defrust run(atom) do
          consume_second(decode(atom))
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    assert second_module.__rustq_source__() =~ "consume_second(decode(atom)?)?;"
  end

  test "configured Rust sources raise structured diagnostics" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule InvalidRustSourceConfigCase do
          use RustQ.Meta, rust_sources: ["test/fixtures/missing_external_callables.rs"]
          alias RustQ.Type, as: R

          @spec run() :: R.nif_result(R.unit())
          defrust run do
            :ok
          end
        end
      end

    assert %Diagnostic{phase: :defrust, kind: :invalid_rust_source} = error.diagnostic
    assert error.diagnostic.details.path =~ "missing_external_callables.rs"
  end

  test "configured Rust packages raise structured diagnostics" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule InvalidRustPackageConfigCase do
          use RustQ.Meta, rust_packages: ["definitely-not-a-real-rustq-test-package"]
          alias RustQ.Type, as: R

          @spec run() :: R.nif_result(R.unit())
          defrust run do
            :ok
          end
        end
      end

    assert %Diagnostic{phase: :defrust, kind: :rust_package_load_failed} = error.diagnostic
    assert error.diagnostic.details.package == "definitely-not-a-real-rustq-test-package"
  end

  test "configured callable modules must expose callable metadata" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule InvalidCallableModuleConfigCase do
          use RustQ.Meta, callable_modules: [String]
          alias RustQ.Type, as: R

          @spec run() :: R.nif_result(R.unit())
          defrust run do
            :ok
          end
        end
      end

    assert %Diagnostic{phase: :defrust, kind: :invalid_callable_module} = error.diagnostic
    assert error.diagnostic.details.module == String
  end

  test "defrust build failures include boundary diagnostic context" do
    error =
      assert_raise Diagnostic.Error, fn ->
        defmodule InvalidDefrustBoundaryCase do
          use RustQ.Meta
          alias RustQ.Type, as: R

          @spec invalid(term()) :: R.nif_result(R.unit())
          defrust invalid(term) do
            %{value: value} = term
            value
          end
        end
      end

    diagnostic = error.diagnostic

    assert diagnostic.phase == :defrust
    assert diagnostic.kind == :build_failed
    assert diagnostic.snippet =~ "%{value: value} = term"
    assert diagnostic.details.function == :invalid
    assert diagnostic.details.arity == 1

    assert %Diagnostic{phase: :lower, kind: :unsupported_binding_pattern} =
             diagnostic.details.cause
  end
end
