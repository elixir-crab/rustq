defmodule RustQ.Config do
  @moduledoc """
  Concise manifest DSL for checked-in generated files.

  Use `rust/2` when a target is a list of RustQ AST items and `generate/2`
  with `content/1` for arbitrary generated content:

      use RustQ.Config

      alias RustQ.Rustler.Term

      rust "native/my_nif/src/generated_term_helpers.rs" do
        Term.helpers()
      end

      generate "lib/my_app/native/generated_stubs.ex" do
        content(MyApp.Codegen.Native.stubs())
      end

  Run `mix rustq.gen` to write targets and `mix rustq.gen --check` in CI.
  """

  alias RustQ.Config.State

  @doc "Imports the manifest macros into `rustq.exs`."
  defmacro __using__(_opts) do
    quote do
      import RustQ.Config
    end
  end

  @doc "Declares an arbitrary generated target with an explicit name."
  defmacro generate(name, path, do: block) do
    quote do
      State.start_target(unquote(name), unquote(path))
      unquote(block)
      State.finish_target()
      State.manifest()
    end
  end

  @doc "Declares an arbitrary generated target, inferring its name from the path."
  defmacro generate(path, do: block) do
    quote do
      path = unquote(path)
      State.start_target(State.target_name(path), path)
      unquote(block)
      State.finish_target()
      State.manifest()
    end
  end

  @doc "Declares a generated Rust item target with an explicit name."
  defmacro rust(name, path, do: block) do
    quote do
      State.put_rust_items(unquote(name), unquote(path), unquote(block_items(block)))
    end
  end

  @doc "Declares a generated Rust item target, inferring its name from the path."
  defmacro rust(path, do: block) do
    quote do
      path = unquote(path)
      State.put_rust_items(State.target_name(path), path, unquote(block_items(block)))
    end
  end

  @doc "Requires a generator source file once and returns the current manifest."
  defmacro require_file(path) do
    quote do
      path = unquote(path)
      module = State.module_from_path(path)

      if module == nil or not Code.ensure_loaded?(module) do
        Code.require_file(path)
      end

      State.manifest()
    end
  end

  @doc "Sets a custom zero-arity build function for the current `generate` target."
  defmacro build(fun) do
    quote do
      State.put_target_option(:build, unquote(fun))
    end
  end

  @doc "Sets content for the current `generate` target."
  defmacro content(value) do
    quote do
      State.put_target_option(:content, unquote(value))
    end
  end

  defp block_items({:__block__, _meta, items}), do: items
  defp block_items(item), do: item
end
