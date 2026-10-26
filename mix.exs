defmodule RustQ.MixProject do
  use Mix.Project

  @version "1.0.0-rc.19"
  @source_url "https://github.com/elixir-crab/rustq"

  def project do
    [
      app: :rustq,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: "Generate Rust code and Rustler NIFs from typed Elixir",
      compilers: [:rustq_native] ++ Mix.compilers(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:ex_unit, :mix, :reach]],
      test_ignore_filters: [~r|test/support/|, ~r|test/corpus/|],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # dev/ holds tools for working on RustQ itself, kept out of the package.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.37", runtime: false},
      {:json_codec, "~> 0.1"},
      {:toml_elixir, "~> 3.1"},
      {:nimble_options, "~> 1.1"},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.6", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:makeup_rust, "~> 0.3", only: :dev}
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "rust.fmt --check",
        "rust.check",
        "rust.clippy",
        "rustq.gen --check",
        "rustq.std --check",
        "rustq.corpus",
        "rustq.templates.check",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0 --ignore lib/rustq/meta/std_methods.ex",
        "reach.check --arch --smells"
      ],
      "rust.fmt": &rust_fmt/1,
      "rust.check": &rust_check/1,
      "rust.clippy": &rust_clippy/1
    ]
  end

  defp rust_fmt(args) do
    rust_cmd(["fmt", "--manifest-path", "native/rustq_nif/Cargo.toml"] ++ args)
  end

  defp rust_check(_args) do
    rust_cmd(["check", "--manifest-path", "native/rustq_nif/Cargo.toml"])
  end

  defp rust_clippy(_args) do
    rust_cmd(["clippy", "--manifest-path", "native/rustq_nif/Cargo.toml", "--", "-D", "warnings"])
  end

  defp rust_cmd(args) do
    {_, status} = System.cmd("cargo", args, into: IO.stream(), stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("cargo #{Enum.join(args, " ")} failed")
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: [
        "lib",
        "native/rustq_nif/Cargo.lock",
        "native/rustq_nif/Cargo.toml",
        "native/rustq_nif/src",
        "priv/fixtures/rustler_template_check/Cargo.lock",
        "priv/fixtures/rustler_template_check/Cargo.toml",
        "priv/fixtures/rustler_template_check/src/lib.rs",
        ".formatter.exs",
        "mix.exs",
        "rustq.exs",
        "README.md",
        "SKILL.md",
        "guides/using-rustq-well.md",
        "guides/internals.md",
        "guides/rustler-generation.md",
        "guides/designing-generators.md",
        "guides/generating-rust.md",
        "guides/reach-plugin.md",
        "guides/compatibility.md",
        "guides/zero-rust-nifs.md",
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/internals.md",
        "guides/using-rustq-well.md",
        "guides/rustler-generation.md",
        "guides/designing-generators.md",
        "guides/generating-rust.md",
        "guides/reach-plugin.md",
        "guides/compatibility.md",
        "guides/zero-rust-nifs.md",
        "SKILL.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      # dev/ holds tools for working on RustQ itself, which the package does not ship.
      filter_modules: fn _module, %{source_path: path} ->
        not String.starts_with?(to_string(path), Path.expand("dev"))
      end,
      groups_for_modules: [
        "Start here": [
          RustQ,
          RustQ.Meta,
          RustQ.Native,
          RustQ.Test,
          RustQ.Type,
          RustQ.Config,
          RustQ.Rustler,
          RustQ.Syn,
          RustQ.Rust,
          RustQ.Rust.Identifier
        ],
        "Rustler generation": ~r/^RustQ\.Rustler\.(?!HelperSelection$|Nif$|SourceEncoder)/,
        "Rust AST nodes":
          ~r/^RustQ\.Rust\.AST\.(?!Builder|ItemBuilder|PatternBuilder|TypeBuilder|Render$|Walk$|NodeDSL$|Schema)/,
        "Rust AST":
          ~r/^RustQ\.Rust\.AST($|\.(Builder|ItemBuilder|PatternBuilder|TypeBuilder|Walk)$)/,
        "Rust source metadata":
          ~r/^RustQ\.(Syn($|\.(?!Doc$))|Cargo($|\.)|Native\.(Descriptor|EnumDescriptor|Ref)$)/,
        "Rusty-Elixir metadata": ~r/^RustQ\.(Binding|Spec)($|\.)/,
        "Generation and templates": [
          RustQ.Generated,
          RustQ.Generated.StaleError,
          RustQ.Splice,
          RustQ.Template,
          RustQ.Sigil,
          RustQ.Rust.Fragment
        ],
        "Diagnostics and tooling": ~r/^RustQ\.(Diagnostic|Error|Reach)/,
        "Lowering internals": ~r/^RustQ\.Meta\./,
        "Code generation internals":
          ~r/^RustQ\.(Codegen($|\.)|Rust\.AST\.(Render|NodeDSL|Schema)($|\.))/,
        "Native and Rustler internals":
          ~r/^RustQ\.(Native\.(ABI|Build|Manifest|Nif|Options)|Rustler\.(HelperSelection|Nif|SourceEncoder))($|\.)/,
        "Tooling internals": [
          RustQ.Clippy,
          RustQ.Corpus,
          RustQ.Config.State,
          RustQ.SourceFingerprint,
          RustQ.Syn.Doc
        ]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end

defmodule Mix.Tasks.Compile.RustqNative do
  @moduledoc false

  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    Rustler.Compiler.compile_crate(:rustq, [crate: "rustq_nif"], [])
    {:ok, []}
  end
end
