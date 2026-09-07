defmodule RustQ.Binding.TypeAliasesTest do
  use ExUnit.Case, async: true
  alias RustQ.Binding.TypeAliases
  alias RustQ.Meta.StandardPointer
  alias RustQ.Meta.Type

  @tag :tmp_dir
  test "expands grouped standard imports and declared alias parameters", %{tmp_dir: dir} do
    path = Path.join(dir, "aliases.rs")
    File.write!(path, "use std::sync::{Arc, Mutex}; type Shared<T> = Arc<Mutex<T>>;")
    aliases = TypeAliases.from_files([path])
    expanded = TypeAliases.expand(Type.parse(quote(do: Shared.t(integer())), %{}), aliases)
    assert expanded.rust == "std::sync::Arc<std::sync::Mutex<i64>>"
    assert StandardPointer.lock_result(expanded).kind == :result
  end

  @tag :tmp_dir
  test "cache refreshes on same-size edits and nested aliases fail explicitly", %{tmp_dir: dir} do
    path = Path.join(dir, "cached.rs")
    File.write!(path, "type Value = u32;")
    first = TypeAliases.from_files([path])
    File.write!(path, "type Value = u64;")
    second = TypeAliases.from_files([path])
    refute first == second
    File.write!(path, "mod inner { type Value = u32; }")
    aliases = TypeAliases.from_files([path])
    assert TypeAliases.expand(Type.parse(quote(do: integer()), %{}), aliases).kind == :i64

    assert_raise ArgumentError, ~r/scoped resolution/, fn ->
      TypeAliases.expand(Type.parse(quote(do: Value.t()), %{}), aliases)
    end
  end

  @tag :tmp_dir
  test "preserves enclosing semantic metadata while expanding nested aliases", %{tmp_dir: dir} do
    path = Path.join(dir, "values.rs")
    File.write!(path, "type Value = u32;")
    aliases = TypeAliases.from_files([path])
    type = Type.parse(quote(do: R.ref(R.option(Value.t()))), %{})
    expanded = TypeAliases.expand(type, aliases)
    assert expanded.kind == :ref
    assert expanded.meta.inner.kind == :option
    assert expanded.meta.inner.meta.inner.kind == :u32
    assert expanded.rust == "&Option<u32>"
  end

  @tag :tmp_dir
  test "generic parameters shadow imports and lifetime expansion is rejected", %{tmp_dir: dir} do
    path = Path.join(dir, "shadow.rs")
    File.write!(path, "use external::T; type Identity<T> = T; type Borrowed<'a> = &'a str;")
    aliases = TypeAliases.from_files([path])

    assert TypeAliases.expand(Type.parse(quote(do: Identity.t(integer())), %{}), aliases).rust ==
             "i64"

    assert_raise ArgumentError, ~r/lifetime alias/, fn ->
      TypeAliases.expand(Type.parse(quote(do: Borrowed.t(R.lifetime(:static))), %{}), aliases)
    end
  end

  @tag :tmp_dir
  test "rejects cycles and conflicting definitions", %{tmp_dir: dir} do
    first = Path.join(dir, "first.rs")
    second = Path.join(dir, "second.rs")
    File.write!(first, "type A = B; type B = A;")
    aliases = TypeAliases.from_files([first])

    assert_raise ArgumentError, ~r/cyclic/, fn ->
      TypeAliases.expand(Type.parse(quote(do: A.t()), %{}), aliases)
    end

    File.write!(second, "type A = u32;")
    aliases = TypeAliases.from_files([first, second])

    assert_raise ArgumentError, ~r/ambiguous/, fn ->
      TypeAliases.expand(Type.parse(quote(do: A.t()), %{}), aliases)
    end
  end
end
