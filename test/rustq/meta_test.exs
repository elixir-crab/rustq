defmodule RustQ.MetaTest do
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

      assert source =~ "Event::Click(Click { name }) =>"
      assert source =~ "Event::Resize(Resize { width, height }) =>"
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

  defmodule SelectorCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @type mode :: :ready | :busy
    @type point :: %{required(:x) => R.f32()}

    defrustimpl Counter do
      @spec value(R.ref(R.path(:Counter))) :: R.i64()
      defrust(value(self), do: self.value)
    end

    defrustimpl Display, for: Counter do
      @spec label(R.ref(R.path(:Counter))) :: R.str()
      defrust(label(self), do: self.label.as_str())
    end
  end

  test "public selectors expose generated type and implementation items" do
    assert MetaAST.items(SelectorCase) == SelectorCase.__rustq_items__()
    assert MetaAST.generated_type_items(SelectorCase) == SelectorCase.__rustq_type_items__()
    assert %RustQ.Rust.AST.Enum{name: :Mode} = MetaAST.enum_type_item!(SelectorCase, :Mode)
    assert %RustQ.Rust.AST.Struct{name: :Point} = MetaAST.struct_type_item!(SelectorCase, "Point")
    assert %RustQ.Rust.AST.Impl{trait: nil} = MetaAST.impl!(SelectorCase, :Counter)

    assert %RustQ.Rust.AST.Impl{trait: %RustQ.Rust.AST.TypePath{parts: [:Display]}} =
             MetaAST.impl!(SelectorCase, "Counter", trait: :Display)
  end

  test "public selectors report absent and mismatched items" do
    assert_raise ArgumentError, ~r/no generated Rust type item named Missing/, fn ->
      MetaAST.type_item!(SelectorCase, :Missing)
    end

    assert_raise ArgumentError, ~r/expected Point to be a generated Rust enum/, fn ->
      MetaAST.enum_type_item!(SelectorCase, :Point)
    end

    assert_raise ArgumentError, ~r/no generated Rust impl for Missing/, fn ->
      MetaAST.impl!(SelectorCase, :Missing)
    end
  end

  test "defrust marks owned standard collection receivers mutable" do
    defmodule OwnedMutationCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec append(R.vec(R.i64()), R.i64()) :: R.vec(R.i64())
      defrust append(values, value) do
        values.push(value)
        values
      end

      @spec remember(HashSet.t(String.t()), String.t()) :: boolean()
      defrust(remember(values, value), do: values.insert(value))
    end

    assert rust_source!(OwnedMutationCase, :append) =~
             "fn append(mut values: Vec<i64>, value: i64)"

    assert rust_source!(OwnedMutationCase, :remember) =~
             "fn remember(mut values: HashSet<String>, value: String)"
  end

  test "defrust keeps shared standard collection receivers immutable" do
    defmodule SharedCollectionCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec count(R.vec(R.i64())) :: R.usize()
      defrust(count(values), do: values.len())
    end

    assert rust_source!(SharedCollectionCase, :count) =~ "fn count(values: Vec<i64>)"
    refute rust_source!(SharedCollectionCase, :count) =~ "mut values"
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

defmodule RustQ.Meta.GeneratedRustTest do
  # Synchronous, so it runs once every test file has defined its fixtures.
  use ExUnit.Case, async: false

  describe "generated Rust" do
    # Fixtures whose Rust is not meant to compile on its own, each with why. The test fails on
    # any other error, and on an entry that no longer has one.
    @known_invalid %{
      "RustQ.Meta.RustMacroTest.DefrustMacroFieldCase" =>
        "a defrustmacro call has no type, so its tail is not wrapped in Ok and its string " <>
          "literal argument is not made a binary",
      "test/corpus/macros/defrustmacro_repeat.rs" =>
        "a defrustmacro call has no type, so its tail is not wrapped in Ok"
    }

    # rustc stops before type checking when names do not resolve, and fixtures may call helpers
    # their Rust sources define elsewhere; those are left out rather than stubbed.
    @resolution_errors ~w(E0405 E0412 E0422 E0423 E0425 E0432 E0433 E0531)

    @tag timeout: 600_000
    test "compiles for every module in the suite that generates it" do
      # The corpus is checked from its golden files, which it compiles modules to match only
      # while its own tests run.
      loaded =
        for {module, _loaded} <- :code.all_loaded(),
            function_exported?(module, :__rustq_source__, 0),
            not String.starts_with?(inspect(module), "RustQ.Corpus."),
            into: %{},
            do: {inspect(module), generated_source(module)}

      sources =
        for path <- Path.wildcard("test/corpus/**/*.rs"),
            into: loaded,
            do: {path, File.read!(path)}

      crate = Path.join(Mix.Project.build_path(), "rustq_generated_rust_check")

      unresolved =
        for {module, code, _message} <- cargo_check!(crate, sources),
            code in @resolution_errors,
            into: MapSet.new(),
            do: module

      checked = Map.drop(sources, MapSet.to_list(unresolved))

      # Run with the whole suite, most fixtures resolve; a broken prelude would leave none.
      # Run on its own, the test sees only its file's fixtures.
      assert map_size(sources) < 20 or map_size(checked) * 2 > map_size(sources)

      errors =
        crate
        |> cargo_check!(checked)
        |> Enum.group_by(&elem(&1, 0), fn {_module, code, message} -> "#{code} #{message}" end)

      assert Map.drop(errors, Map.keys(@known_invalid)) == %{}
      assert Map.keys(@known_invalid) -- Map.keys(errors) == []
    end
  end

  defp generated_source(module) do
    if function_exported?(module, :__rustq_native_source__, 0),
      do: module.__rustq_native_source__(),
      else: module.__rustq_source__()
  end

  # Checks each source as a module of one crate, in a file of its own, and returns rustc's
  # errors as `{module, code, message}`, read from Cargo's JSON diagnostics.
  defp cargo_check!(crate, sources) do
    src = Path.join(crate, "src")
    File.rm_rf!(src)
    File.mkdir_p!(src)

    File.write!(Path.join(crate, "Cargo.toml"), """
    [package]
    name = "rustq_generated_rust_check"
    version = "0.0.0"
    edition = "2021"

    [dependencies]
    rustler = "0.37"
    """)

    files =
      sources
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new(fn {{module, source}, index} ->
        File.write!(Path.join(src, "m#{index}.rs"), module_source(source))
        {"src/m#{index}.rs", module}
      end)

    File.write!(Path.join(src, "lib.rs"), [
      "#![allow(warnings)]\n",
      "use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};\n",
      "use std::collections::HashMap;\n",
      Enum.map(files, fn {"src/" <> file, _module} -> "mod #{Path.rootname(file)};\n" end)
    ])

    {output, _status} =
      System.cmd("cargo", ["check", "--message-format", "json"],
        cd: crate,
        env: [{"CARGO_TARGET_DIR", Path.join(crate, "target")}],
        stderr_to_stdout: false
      )

    for line <- String.split(output, "\n", trim: true),
        %{"reason" => "compiler-message", "message" => message} <- [JSON.decode!(line)],
        message["level"] == "error",
        span = Enum.find(message["spans"], & &1["is_primary"]),
        do: {Map.get(files, span["file_name"]), message["code"]["code"], message["message"]}
  end

  # A source with the parent's imports and the atoms it names, declared as rustler would.
  defp module_source(source) do
    atoms =
      case RustQ.Syn.atom_references(source) do
        {:ok, []} -> ""
        {:ok, names} -> names |> RustQ.Rustler.Atom.declaration() |> RustQ.Rust.render()
        {:error, _errors} -> ""
      end

    ["use super::*;\n", atoms, "\n", source]
  end
end
