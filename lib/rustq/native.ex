defmodule RustQ.Native do
  @moduledoc """
  Builds and loads a Rustler NIF crate generated entirely from Rusty-Elixir.

  `use RustQ.Native` makes the current module a native compilation unit and
  imports `RustQ.Meta`. Public entrypoints use `defnif`; generated helper
  functions use `defrust` or `defrustp`.

      defmodule MyApp.Native do
        use RustQ.Native

        @spec add(integer(), integer()) :: integer()
        defnif add(left, right), do: left + right
      end

  RustQ generates the crate under the Mix build directory, compiles it with
  Cargo, copies the native library into the application's `priv/native`
  directory, and injects the NIF loader. No checked-in Rust or Cargo files are
  required for this path.

  Genuine native policy remains explicit. Use `:otp_app`, `:crate`, `:mode`,
  `:cargo`, or `:crates` only when their inferred defaults are not appropriate.
  Generated crates are formatted before compilation. Existing
  `RustQ.Meta` options such as `:rust_sources`, `:rust_packages`, and
  `:callable_modules` may be passed alongside them.

  Existing and precompiled crates can use RustQ as an item generator without
  transferring build or loading ownership:

      use RustQ.Native, build: false, load: false

  `RustQ.Native.items/1` then returns ABI-prepared functions, codecs, and
  resource implementations for splicing into the externally-owned crate.
  """

  alias RustQ.Native.{ABI, Build, Options}
  alias RustQ.Rust.AST
  alias RustQ.Rust.Identifier
  @doc false
  defmacro __using__(opts) do
    native_opts = Options.native_options!(opts, __CALLER__)

    manifest =
      if native_opts[:build] do
        Build.prepare_manifest!(native_opts)
      end

    package_metadata =
      if manifest do
        Enum.map(native_opts[:crates], fn {package, _spec} ->
          {package, manifest_path: manifest}
        end)
      else
        []
      end

    meta_opts =
      opts
      |> Keyword.drop(Options.names())
      |> Keyword.update(:rust_packages, package_metadata, &(List.wrap(&1) ++ package_metadata))

    rust_modules =
      Enum.map(native_opts[:crates], fn {package, _spec} ->
        normalized = String.replace(package, "-", "_")
        alias_name = normalized |> Macro.camelize() |> Identifier.atom!()
        {[alias_name], [Identifier.atom!(normalized)]}
      end)

    quote do
      Module.register_attribute(__MODULE__, :rustq_native_opts, persist: true)
      @rustq_native_opts unquote(Macro.escape(native_opts))
      use RustQ.Meta, unquote(meta_opts)

      for mapping <- unquote(Macro.escape(rust_modules)) do
        @rustq_mod_aliases mapping
      end
    end
  end

  @doc "Returns ABI-prepared Rust items from a `RustQ.Native` module."
  @spec items(module()) :: [AST.item()]
  def items(module) when is_atom(module) do
    module.__rustq_native_items__()
  end

  @doc "Returns ABI-prepared Rust source without crate imports or initialization."
  @spec source(module()) :: String.t()
  def source(module) when is_atom(module) do
    module.__rustq_native_source__()
  end

  @doc false
  def __compile_native__(env, values, opts, exports) do
    module = env.module
    items = ABI.native_items(values)
    item_source = RustQ.Rust.render_all(items)
    loader = Build.maybe_build_and_loader(module, items, opts)

    native_exports =
      quote do
        @doc false
        def __rustq_native_items__ do
          unquote(Macro.escape(items))
        end

        @doc false
        def __rustq_native_source__ do
          unquote(item_source)
        end
      end

    quote do
      unquote(exports)
      unquote(native_exports)
      unquote(loader)
    end
  end
end
