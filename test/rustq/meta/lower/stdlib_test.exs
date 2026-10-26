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
