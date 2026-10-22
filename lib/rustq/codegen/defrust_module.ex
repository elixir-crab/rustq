defmodule RustQ.Codegen.DefrustModule do
  @moduledoc """
  `use RustQ.Codegen.DefrustModule` sets up a `RustQ.Meta` module for RustQ's own
  generated native support: it reads callable metadata from the native crate's sources,
  requires the given `callable_modules`, and defines `asts/0` returning the module's
  functions as crate-visible Rust items.
  """

  alias RustQ.Meta.AST, as: MetaAST

  @native_sources [
    "native/rustq_nif/src/decode.rs",
    "native/rustq_nif/src/parse.rs",
    "native/rustq_nif/src/parse_item.rs",
    "native/rustq_nif/src/parse_type.rs"
  ]

  defmacro __using__(opts) do
    callable_modules = Keyword.get(opts, :callable_modules, [])

    opts =
      Keyword.update(opts, :rust_sources, @native_sources, fn sources ->
        (@native_sources ++ List.wrap(sources)) |> Enum.uniq()
      end)

    requires = Enum.map(callable_modules, &quote(do: require(unquote(&1))))

    quote do
      unquote_splicing(requires)
      use RustQ.Meta, unquote(opts)

      alias RustQ.Type, as: R

      @before_compile RustQ.Codegen.DefrustModule
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def asts do
        Enum.map(unquote(MetaAST).functions(__MODULE__), &%{&1 | vis: :crate})
      end
    end
  end
end
