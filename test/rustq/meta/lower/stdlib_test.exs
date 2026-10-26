defmodule RustQ.Meta.Lower.StdlibTest do
  use ExUnit.Case, async: true

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust.AST

  import RustQ.Test, only: [rust_source!: 2]

  defmodule Collections do
    @moduledoc "Elixir's collection functions on Rust's collections, through a reference."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @type state :: %{
            required(:keys) => R.vec(String.t()),
            required(:index) => HashMap.t(R.u32(), R.usize())
          }

    @spec sizes(R.ref(state()), R.ref(MapSet.t(R.u32()))) :: R.usize()
    defrust(sizes(state, seen),
      do: length(state.keys) + map_size(state.index) + MapSet.size(seen)
    )

    @spec empty(R.ref(state())) :: R.bool()
    defrust(empty(state), do: Enum.empty?(state.keys) or state.index == %{})

    @spec fresh() :: state()
    defrust(fresh(), do: %{keys: [], index: %{}})

    @spec counted(R.u32()) :: HashMap.t(R.u32(), R.usize())
    defrust(counted(id), do: %{id => 1})

    @spec ids(R.ref(state())) :: R.vec(R.u32())
    defrust(ids(state), do: for({id, _at} <- state.index, do: id))

    @spec numbers(R.mut_ref(R.vec(R.u32())), R.u32()) :: R.unit()
    defrust numbers(values, count) do
      for number <- 1..count//1 do
        values.push(number)
      end
    end

    @spec tag(R.ref(String.t())) :: R.option(R.u32())
    defrust(tag(name), do: if(name.is_empty(), do: nil, else: some(name.len() |> cast(R.u32()))))

    @spec firsts(R.slice(String.t())) :: R.vec(R.usize())
    defrust firsts(names) do
      first =
        for {name, index} <- names |> Enum.with_index() |> Enum.reverse(),
            {:some, tag} <- [tag(name)],
            into: %{},
            do: {tag, index}

      for name <- names, {:some, tag} <- [tag(name)], do: first[tag]
    end

    @spec regrouped(R.vec(String.t())) :: R.vec(String.t())
    defrust regrouped(names) do
      {long, short} = Enum.split_with(names, fn name -> name.len() > 3 end)
      short ++ copies(long ++ long)
    end

    @spec copies(R.slice(String.t())) :: R.vec(String.t())
    defrust(copies(names), do: Enum.map(names, fn name -> name.clone() end))

    @spec grown(R.vec(R.u32()), R.u32()) :: R.vec(R.u32())
    defrust grown(values, count) do
      values = values ++ [count]
      values
    end

    @typep paths :: HashMap.t(R.u32(), R.vec(R.usize()))
    @typep tables :: HashMap.t(R.vec(R.usize()), paths())

    @spec indexed(R.slice(R.u32())) :: paths()
    defrust indexed(keys) do
      keys
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {key, index}, table ->
        Map.update(table, key, [index], fn found -> found ++ [index] end)
      end)
    end

    @spec single(R.vec(R.u32())) :: R.result(R.u32(), R.usize())
    defrust single(keys) do
      found = Enum.reduce(keys, [], fn key, found -> kept(key, found) end)

      case found do
        [key] -> {:ok, key}
        found -> {:error, length(found)}
      end
    end

    @spec kept(R.u32(), R.vec(R.u32())) :: R.vec(R.u32())
    defrust(kept(key, found), do: found ++ [key])

    @spec first_value(R.slice(R.u32()), R.slice(R.usize())) :: R.u32()
    defrust first_value(values, path) do
      case path do
        [index | _rest] -> values[index]
        [] -> 0
      end
    end

    @spec lookup(R.ref(tables()), R.slice(R.usize()), R.u32()) :: R.vec(R.usize())
    defrust(lookup(tables, at, key), do: Map.get(tables[at], key, []))

    @spec widened(R.ref(MapSet.t(R.u32())), R.vec(R.u32())) :: MapSet.t(R.u32())
    defrust(widened(seen, keys), do: MapSet.union(seen, MapSet.new(keys)))

    @spec bumped(R.vec(R.u32()), R.usize()) :: R.vec(R.u32())
    defrust(bumped(values, index), do: List.replace_at(values, index, values[index] + 1))

    @spec sorted_pairs(R.vec({R.u32(), R.u32()})) :: R.vec({R.u32(), R.u32()})
    defrust(sorted_pairs(pairs), do: Enum.sort(pairs))

    @spec counted_len(R.mut_ref(R.vec(R.usize()))) :: R.usize()
    defrust counted_len(values) do
      position = length(values)
      values.push(position)
      position
    end

    @spec sized(R.ref(paths())) :: R.usize()
    defrust(sized(paths), do: map_size(paths))

    @spec empty_size() :: R.usize()
    defrust(empty_size(), do: sized(%{}))

    @spec wrapped(R.vec(R.u32())) :: R.vec(R.option(R.u32()))
    defrust(wrapped(values), do: Enum.map(values, fn value -> some(value) end))

    @spec joined(R.vec(R.u32()), R.vec(R.u32())) :: R.vec(R.u32())
    defrust(joined(left, right), do: left ++ right)
  end

  test "counts and emptiness of lists, maps, and sets are Rust's" do
    assert rust_source!(Collections, :sizes) =~
             "state.keys.len() + state.index.len() + seen.len()"

    assert rust_source!(Collections, :empty) =~
             "state.keys.is_empty() || state.index.is_empty()"
  end

  test "empty and literal maps build where a map is expected" do
    assert rust_source!(Collections, :fresh) =~ "index: HashMap::new()"
    assert rust_source!(Collections, :counted) =~ "HashMap::from([(id, 1)])"
  end

  test "a map behind a reference is iterated by reference, copying copy keys" do
    assert rust_source!(Collections, :ids) =~
             "state.index.iter().map(|(key, value)| (*key, *value))"
  end

  test "a range with a step counts up between dynamic bounds" do
    assert rust_source!(Collections, :numbers) =~ "for number in 1..=count {"
  end

  test "a map a comprehension builds is indexed by a borrowed key" do
    source = rust_source!(Collections, :firsts)

    assert source =~ ".rev()\n        .map("
    refute source =~ ".collect()\n        .into_iter()"
    assert source =~ "first[&tag]"
  end

  test "a list split or joined for a slice is borrowed" do
    source = rust_source!(Collections, :regrouped)

    assert source =~ ".chain(long.iter().cloned())"
    assert source =~ ".collect::<Vec<String>>(),"
  end

  test "a reduction grows the accumulator it builds in place" do
    source = rust_source!(Collections, :indexed)

    assert source =~ "HashMap::new(),"
    assert source =~ "Some(found) => {"
    assert source =~ "rustq_updated.push(index);"
  end

  test "a reduction's list is matched as a slice, and a slice index is copied" do
    assert rust_source!(Collections, :single) =~ "match found.as_slice() {"
    assert rust_source!(Collections, :single) =~ "[key] => Ok(*key),"
    assert rust_source!(Collections, :first_value) =~ "values[*index]"
  end

  test "a map read out of a map of maps is typed by its alias" do
    assert rust_source!(Collections, :lookup) =~
             "tables[at].get(&key).cloned().unwrap_or_default()"
  end

  test "a set behind a reference is copied, never updated in place" do
    assert rust_source!(Collections, :widened) =~ "seen.clone()"
  end

  test "replace_at computes the item, then sets it in place unless the index is past the end" do
    source = rust_source!(Collections, :bumped)

    assert source =~ "let rustq_item = values[index] + 1;"
    assert source =~ "if let Some(rustq_slot) = rustq_updated.get_mut(index) {"
    assert source =~ "*rustq_slot = rustq_item;"
  end

  test "lists of tuples sort as Elixir sorts them, and a count is the integer its use needs" do
    assert rust_source!(Collections, :sorted_pairs) =~ "rustq_updated.sort();"
    assert rust_source!(Collections, :counted_len) =~ "let position = values.len();"
  end

  test "an empty map passed for a reference to one is borrowed" do
    assert rust_source!(Collections, :empty_size) =~ "sized(&HashMap::new())"
  end

  test "++ concatenates lists" do
    assert rust_source!(Collections, :joined) =~ "rustq_updated.extend(right);"
    assert rust_source!(Collections, :grown) =~ "values.push(count);"
  end

  test "normalizes remote stdlib calls and local Kernel forms" do
    assert {:ok, %Call{module: Enum, function: :count, args: [_values]}} =
             Call.normalize(quote(do: Enum.count(values)))

    assert {:ok, %Call{module: Kernel, function: :byte_size, args: [_value]}} =
             Call.normalize(quote(do: byte_size(value)))

    assert {:ok, piped} =
             Call.pipe_remote(
               quote(do: values),
               quote(do: Enum.map(fn value -> value * 2 end))
             )

    assert {:ok, %Call{module: Enum, function: :map, args: [_values, _mapper]}} =
             Call.normalize(piped)
  end

  test "stdlib modules synthesize collection result types" do
    integer = RustQ.Spec.type(quote(do: integer()))
    values = Type.vec(integer)
    env = Typing.env(vars: %{initial: integer, values: values})

    assert %Type{kind: :i64} = Typing.synth(quote(do: Enum.count(values)), env)

    assert %Type{kind: :option, meta: %{inner: %Type{kind: :i64}}} =
             Typing.synth(quote(do: List.first(values)), env)

    assert %Type{kind: :i64} =
             Typing.synth(
               quote do
                 values
                 |> Enum.map(fn value -> value * value end)
                 |> Enum.reduce(initial, fn value, total -> value + total end)
               end,
               env
             )
  end

  test "lowers Enum reverse through the stdlib dispatcher" do
    integer = RustQ.Spec.type(quote(do: integer()))

    assert [
             %AST.Return{
               expr: %AST.MethodCall{
                 method: :collect,
                 receiver: %AST.MethodCall{
                   method: :rev,
                   receiver: %AST.MethodCall{method: :into_iter}
                 }
               }
             }
           ] =
             Lower.quoted_body(quote(do: Enum.reverse(values)), Type.vec(integer), %{
               values: Type.vec(integer)
             })
  end

  test "rejects integer division spelled as floating-point division" do
    integer = RustQ.Spec.type(quote(do: integer()))
    float = RustQ.Spec.type(quote(do: float()))

    assert_raise Diagnostic.Error, ~r/explicit floating-point conversion/, fn ->
      Lower.quoted_body(quote(do: left / right), float, %{left: integer, right: integer})
    end
  end

  test "constant tuple size preserves evaluation of its argument" do
    integer = RustQ.Spec.type(quote(do: integer()))
    tuple = Type.tuple([integer, integer])

    assert [
             %AST.Return{
               expr: %AST.BlockExpr{
                 body: [
                   %AST.Let{pattern: %AST.PatWildcard{}, expr: %AST.Var{name: :value}},
                   %AST.Return{expr: %AST.Literal{value: 2}}
                 ]
               }
             }
           ] = Lower.quoted_body(quote(do: tuple_size(value)), integer, %{value: tuple})
  end

  test "has_key rejects maps with no known structural type" do
    assert_raise Diagnostic.Error, ~r/typed Map lowering requires/, fn ->
      Lower.quoted_body(quote(do: Map.has_key?(value, :x)), nil)
    end
  end

  test "rejects descending ranges instead of silently changing Elixir semantics" do
    assert_raise Diagnostic.Error, ~r/require ascending integer literal bounds/, fn ->
      Lower.quoted_body(quote(do: 3..1), nil)
    end
  end
end
