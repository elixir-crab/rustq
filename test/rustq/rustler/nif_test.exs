defmodule RustQ.Rustler.NifTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rustler.{Atom, Nif}

  test "builds Rustler helpers" do
    code =
      "__rq_items!();"
      |> RustQ.render!("native.rs",
        splice: [
          items: [
            Atom.declaration([:ok, :error, {"r#type", "type"}]),
            Nif.wrapper(:add, args: [a: :i64, b: :i64], returns: :i64),
            Nif.init(RustQ.Native)
          ]
        ]
      )

    assert code =~ "rustler::atoms!"
    assert code =~ "#[rustler::nif]"
    assert code =~ "fn add(a: i64, b: i64) -> i64"
    assert code =~ "add_impl(a, b)"
    assert code =~ ~s|rustler::init! {|
    assert code =~ ~s|"Elixir.RustQ.Native"|
  end

  test "derives NIF export signatures from implementation source" do
    code =
      "__rq_items!();"
      |> RustQ.render!("nif_wrappers.rs",
        splice: [
          items:
            Nif.wrappers_from_source(
              "test/fixtures/nif_impls.rs",
              [parse_nif: [], compile_nif: [attrs: [A.allow_attr(:too_many_arguments)]]],
              schedule: :dirty_cpu
            )
        ]
      )

    assert code =~ ~s|#[rustler::nif(schedule = "DirtyCpu")]|
    assert code =~ "fn parse_nif<'a>(env: Env<'a>, source: &str) -> NifResult<Term<'a>>"
    assert code =~ "parse_nif_impl(env, source)"
    assert code =~ "#[allow(too_many_arguments)]"
    assert code =~ "compile_nif_impl(env, source, minify)"
  end

  test "derives Elixir NIF stub arities from implementation source" do
    source =
      Nif.stubs_from_source(
        "test/fixtures/nif_impls.rs",
        [parse_nif: [], compile_nif: []],
        RustQ.Test.GeneratedNifStubs
      )

    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "def parse_nif(_source)"
    assert source =~ "def compile_nif(_source, _minify)"
    refute source =~ "_env"
  end

  test "derives wrappers and one stub module from multiple Rust sources" do
    groups = [
      {"test/fixtures/nif_impls.rs", [parse_nif: []]},
      {"test/fixtures/nif_more_impls.rs", [lint_nif: [], borrow_nif: []]}
    ]

    rust =
      "__rq_items!();"
      |> RustQ.render!("nif_wrappers.rs",
        splice: [
          items: Nif.wrappers_from_sources(groups, schedule: :dirty_cpu)
        ]
      )

    elixir =
      Nif.stubs_from_sources(
        groups,
        RustQ.Test.MultiSourceNifStubs
      )

    assert rust =~ "fn parse_nif<'a>(env: Env<'a>, source: &str)"
    assert rust =~ "fn lint_nif<'a>(env: Env<'a>, source: &str, fix: bool)"
    assert rust =~ "fn borrow_nif<'a, 'b>(env: Env<'a>, source: &'b str)"
    assert elixir =~ "def parse_nif(_source)"
    assert elixir =~ "def lint_nif(_source, _fix)"
    assert elixir =~ "def borrow_nif(_source)"
  end

  test "derives one stub module from mixed Syn and RustQ AST functions" do
    syn_function =
      "test/fixtures/nif_impls.rs"
      |> RustQ.Syn.parse_file!()
      |> RustQ.Syn.functions()
      |> Enum.find(&(&1.name == "parse_nif_impl"))

    ast_function = %RustQ.Rust.AST.Function{
      name: :scene_index_roots,
      args: [
        A.arg(:env, A.type_path([:rustler, :Env], lifetimes: [:a])),
        A.arg(:resource, A.type_path(:SceneIndexResource))
      ],
      returns: A.type_path(:Term, lifetimes: [:a]),
      body: []
    }

    zero_arity_function = %RustQ.Rust.AST.Function{
      name: :font_families,
      args: [A.arg(:env, A.type_path([:rustler, :Env], lifetimes: [:a]))],
      returns: A.type_path(:Term, lifetimes: [:a]),
      body: []
    }

    source =
      Nif.stubs_from_functions(
        [{:parse_nif, syn_function}, ast_function, zero_arity_function],
        RustQ.Test.MixedNifStubs
      )

    assert source =~ "def parse_nif(_source)"
    assert source =~ "def scene_index_roots(_resource)"
    assert source =~ "def font_families do"
    refute source =~ "def font_families()"
    refute source =~ "_env"
  end

  test "one manifest generates matching Rust exports and Elixir stubs" do
    manifest = [parse_nif: [], compile_nif: []]

    rust =
      "__rq_items!();"
      |> RustQ.render!("nif_wrappers.rs",
        splice: [
          items:
            Nif.wrappers_from_source(
              "test/fixtures/nif_impls.rs",
              manifest,
              schedule: :dirty_cpu
            )
        ]
      )

    suffix = System.unique_integer([:positive])
    stubs_module = Module.concat([RustQ.Test, "GeneratedNifStubs#{suffix}"])
    consumer_module = Module.concat([RustQ.Test, "NifConsumer#{suffix}"])

    elixir =
      Nif.stubs_from_source(
        "test/fixtures/nif_impls.rs",
        manifest,
        stubs_module
      )

    Code.compile_string(elixir)

    Module.create(
      consumer_module,
      quote(do: use(unquote(stubs_module))),
      Macro.Env.location(__ENV__)
    )

    assert rust =~ "fn parse_nif<'a>(env: Env<'a>, source: &str)"
    assert rust =~ "fn compile_nif<'a>(env: Env<'a>, source: &str, minify: bool)"
    assert function_exported?(consumer_module, :parse_nif, 1)
    assert function_exported?(consumer_module, :compile_nif, 2)
    refute function_exported?(consumer_module, :parse_nif, 2)
  end

  test "builds NIF export functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("nif_wrappers.rs",
        splice: [
          items:
            Nif.wrappers(
              render_png: [
                args: [env: "Env<'a>", batch: "Term<'a>"],
                returns: "NifResult<Term<'a>>",
                lifetimes: [:a],
                schedule: :dirty_cpu
              ],
              register_file: [
                args: [path: :String, data: "rustler::Binary<'a>"],
                returns: "rustler::Atom",
                lifetimes: [:a],
                impl: "files::register"
              ]
            )
        ]
      )

    assert code =~ ~s|#[rustler::nif(schedule = "DirtyCpu")]|
    assert code =~ "fn render_png<'a>(env: Env<'a>, batch: Term<'a>) -> NifResult<Term<'a>>"
    assert code =~ "render_png_impl(env, batch)"
    assert code =~ "#[rustler::nif]"

    assert code =~
             "fn register_file<'a>(path: String, data: rustler::Binary<'a>) -> rustler::Atom"

    assert code =~ "files::register(path, data)"
  end
end
