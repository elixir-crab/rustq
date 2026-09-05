defmodule RustQ.Binding.SourceTest do
  use ExUnit.Case, async: true

  alias RustQ.Binding.Callable
  alias RustQ.Binding.Source
  alias RustQ.Meta.Type

  @moduletag :tmp_dir

  test "refreshes package callables after a same-size edit with unchanged timestamp", %{
    tmp_dir: dir
  } do
    package = "rustq_binding_refresh"
    manifest = Path.join(dir, "Cargo.toml")
    source = Path.join([dir, "src", "lib.rs"])
    File.mkdir_p!(Path.dirname(source))

    File.write!(
      manifest,
      TomlElixir.encode!(%{
        "package" => %{"name" => package, "version" => "0.1.0", "edition" => "2021"}
      })
    )

    File.write!(source, "pub fn value() -> i64 { 1 }\n")
    timestamp = File.stat!(source).mtime

    resolve = fn ->
      module = Module.concat(__MODULE__, "PackageConsumer#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            @rustq_rust_packages [{unquote(package), [manifest_path: unquote(manifest)]}]
            @callables RustQ.Binding.Source.external_callables(__MODULE__)
            def callables, do: @callables
          end
        end
      )

      Enum.find(module.callables(), &(&1.name == "value"))
    end

    assert %Callable{returns: %Type{kind: :i64}} = resolve.()
    File.write!(source, "pub fn value() -> u64 { 1 }\n")
    File.touch!(source, timestamp)
    assert %Callable{returns: %Type{kind: :u64}} = resolve.()
  end

  test "expands relative Rust source paths from current working directory" do
    assert Source.rust_source_paths("test/fixtures/external_callables.rs") == [
             Path.expand("test/fixtures/external_callables.rs", File.cwd!())
           ]
  end

  test "resolves configured Rust source callables at compile time" do
    callables =
      compile_source_module!("""
      pub fn make_shader(color: Color) -> Option<Shader> { todo!() }
      """)

    assert %Callable{
             name: "make_shader",
             kind: :function,
             args: [%{name: "color", type: %Type{rust: "Color"}}],
             returns: %Type{kind: :option, rust: "Option<Shader>"}
           } = Enum.find(callables, &(&1.name == "make_shader"))
  end

  test "annotates From conversions without matching similarly named traits" do
    callables =
      compile_source_module!("""
      pub struct Color;
      pub struct Color4f;
      pub struct SourceString;

      impl From<Color> for Color4f {
        pub fn from(value: Color) -> Color4f { todo!() }
      }

      impl FromStr for Color4f {
        pub fn from(value: SourceString) -> Color4f { todo!() }
      }

      pub fn consume_color(color: Color4f) { todo!() }
      """)

    %Callable{args: [%{type: color4f}]} = Enum.find(callables, &(&1.name == "consume_color"))

    assert "Color" in color4f.meta.equivalent_rust_names
    refute "SourceString" in color4f.meta.equivalent_rust_names
  end

  test "resolves callable modules without holding the cache lock" do
    suffix = System.unique_integer([:positive])
    callable_module = Module.concat(__MODULE__, "Callable#{suffix}")
    consumer_module = Module.concat(__MODULE__, "Consumer#{suffix}")
    observer_key = {__MODULE__, suffix}
    :persistent_term.put(observer_key, self())
    on_exit(fn -> :persistent_term.erase(observer_key) end)

    Code.compile_quoted(
      quote do
        defmodule unquote(callable_module) do
          def __rustq_callables__ do
            send(:persistent_term.get(unquote(Macro.escape(observer_key))), :callable_resolved)
            []
          end
        end
      end
    )

    cache_key = {Source, :callables, {:callable_module, callable_module}}
    lock_resource = {Source, :cache_fill, cache_key}
    parent = self()

    lock_holder =
      spawn_link(fn ->
        :global.trans(
          {lock_resource, self()},
          fn ->
            send(parent, :cache_lock_held)

            receive do
              :release_cache_lock -> :ok
            end
          end,
          [node()],
          :infinity
        )
      end)

    assert_receive :cache_lock_held

    compiler =
      Task.async(fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(consumer_module) do
              @rustq_callable_modules [unquote(callable_module)]
              @callables RustQ.Binding.Source.external_callables(__MODULE__)
              def __callables__, do: @callables
            end
          end
        )
      end)

    assert_receive :callable_resolved
    # Callable resolution must not depend on the obsolete outer cache lock.
    Task.await(compiler)
    send(lock_holder, :release_cache_lock)
  end

  test "observes recompiled callable providers in the same VM" do
    suffix = System.unique_integer([:positive])
    provider = Module.concat(__MODULE__, "Reloaded#{suffix}")

    define_provider = fn value ->
      Code.compile_quoted(
        quote do
          defmodule unquote(provider) do
            def __rustq_callables__, do: [unquote(value)]
          end
        end
      )
    end

    resolve = fn ->
      consumer = Module.concat(__MODULE__, "ReloadConsumer#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(consumer) do
            @rustq_callable_modules [unquote(provider)]
            @callables RustQ.Binding.Source.external_callables(__MODULE__)
            def callables, do: @callables
          end
        end
      )

      consumer.callables()
    end

    define_provider.(:before_reload)
    assert resolve.() == [:before_reload]
    :code.purge(provider)
    :code.delete(provider)
    define_provider.(:after_reload)
    assert resolve.() == [:after_reload]
  end

  defp compile_source_module!(source) do
    path = tmp_rust!(source)
    module = Module.concat(__MODULE__, "SourceCase#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use RustQ.Meta, rust_sources: [unquote(path)]

          @callables RustQ.Binding.Source.external_callables(__MODULE__)
          def __callables__, do: @callables
        end
      end
    )

    module.__callables__()
  after
    cleanup_tmp_rust()
  end

  defp tmp_rust!(source) do
    path = Path.join(System.tmp_dir!(), "rustq_source_#{System.unique_integer([:positive])}.rs")
    Process.put({__MODULE__, :tmp_paths}, [path | Process.get({__MODULE__, :tmp_paths}, [])])
    File.write!(path, source)
    path
  end

  defp cleanup_tmp_rust do
    {__MODULE__, :tmp_paths}
    |> Process.get([])
    |> Enum.each(&File.rm/1)

    Process.delete({__MODULE__, :tmp_paths})
  end
end
