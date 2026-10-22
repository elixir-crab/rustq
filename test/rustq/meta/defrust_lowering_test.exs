defmodule RustQ.Meta.DefrustLoweringTest do
  use RustQ.Test, async: true

  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Meta.GeneratedCase, as: Generated
  alias RustQ.Native.Nif

  defmodule FilteredComprehensionCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec evens(R.vec(R.i64())) :: R.vec(R.i64())
    defrust(evens(values), do: for(value <- values, rem(value, 2) == 0, do: value * 10))

    @spec present(R.vec(R.option(R.i64()))) :: R.vec(R.i64())
    defrust(present(values), do: for({:some, value} <- values, do: value))

    @spec pairs(R.vec(R.i64()), R.vec(R.i64())) :: R.vec({R.i64(), R.i64()})
    defrust pairs(left, right) do
      for x <- left, y <- right.clone(), x < y, do: {x, y}
    end

    @spec by_key(R.vec({R.i64(), R.i64()})) :: HashMap.t(R.i64(), R.i64())
    defrust(by_key(pairs),
      do: for({key, value} <- pairs, into: HashMap.new(), do: {key, value})
    )
  end

  defmodule LoopComprehensionCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec positive(R.vec(R.option(R.i64()))) :: R.vec(R.i64())
    defrust positive(values) do
      found = Vec.new()

      for {:some, value} <- values, value > 0 do
        found.push(value)
      end

      found
    end
  end

  defmodule PatternPathCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    defrustmod(Kind, as: [:kinds])

    @spec label(R.option(R.u32())) :: R.u32()
    defrust label(kind) do
      case kind do
        {:some, Kind.FANCY} -> 1
        {:some, Kind.PLAIN} -> 2
        _ -> 0
      end
    end

    @spec pair_label(R.option(R.u32()), R.option(R.u32())) :: R.u32()
    defrust pair_label(left, right) do
      case {left, right} do
        {{:some, Kind.FANCY}, {:some, value}} -> value
        {_left, {:some, Kind.PLAIN}} -> 100
        _ -> 0
      end
    end

    @spec listed(R.u32()) :: R.bool()
    defrust(listed(value), do: ref([Kind.PLAIN, Kind.FANCY]).contains(ref(value)))

    @spec checked(R.option(R.i64()), R.bool()) :: R.option(R.i64())
    defrust checked(value, enabled) do
      with {:some, value} <- value,
           true <- enabled do
        some(value * 2)
      else
        _ -> nil
      end
    end

    @spec parsed(R.i64()) :: R.result(R.i64(), R.u32())
    defrust(parsed(value), do: if(value > 0, do: ok(value), else: err(0)))

    @spec doubled(R.i64()) :: R.result(R.i64(), R.u32())
    defrust doubled(value) do
      with {:ok, value} <- parsed(value) do
        ok(value * 2)
      end
    end

    @spec bumped(R.option(R.i64())) :: R.option(R.i64())
    defrust bumped(value) do
      with {:some, value} <- value do
        some(value + 1)
      end
    end

    @spec lookup(R.u32()) :: R.option(R.u32())
    defrust(lookup(kind), do: if(kind == Kind.FANCY, do: some(kind), else: nil))

    @spec other_kinds(R.vec(R.option(R.u32())), R.u32()) :: R.vec(R.option(R.u32()))
    defrust other_kinds(kinds, kind) do
      found = lookup(kind)
      kinds.retain(fn other -> other != ref(found) end)
      kinds
    end
  end

  defmodule StructUpdateCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @typep tree :: %{
             required(:label) => R.i64(),
             required(:scale) => R.f64(),
             required(:children) => R.vec(tree())
           }

    @spec relabel(tree(), R.i64()) :: tree()
    defrust relabel(node, label) do
      %{
        node
        | label: label,
          children: node.children |> into_iter() |> map(fn child -> grow(child) end) |> collect()
      }
    end

    @spec grow(tree()) :: tree()
    defrust(grow(node), do: %{node | scale: node.scale * 2.0})

    @spec sample() :: tree()
    defrust sample() do
      leaf = struct_literal(Tree, label: 2, scale: 1.0, children: Vec.new())
      struct_literal(Tree, label: 1, scale: 1.0, children: [leaf])
    end
  end

  defmodule ImportedTypeCase do
    use RustQ.Meta,
      callable_modules: [RustQ.Meta.DefrustLoweringTest.StructUpdateCase]

    alias RustQ.Meta.DefrustLoweringTest.StructUpdateCase
    alias RustQ.Type, as: R

    @typep forest :: R.vec(StructUpdateCase.tree())

    @typep size :: :small | :large
    @typep sized :: %{required(:size) => size()}

    @spec large() :: sized()
    defrust(large(), do: struct_literal(Sized, size: :large))

    @spec size(R.ref(StructUpdateCase.tree())) :: size()
    defrust(size(node), do: if(node.scale < 1.0, do: :small, else: :large))

    @spec size_label(size()) :: R.i64()
    defrust size_label(size) do
      case size do
        :small -> 1
        :large -> 2
      end
    end

    @spec shrink(StructUpdateCase.tree()) :: StructUpdateCase.tree()
    defrust(shrink(node), do: %{node | scale: node.scale / 2.0})

    @spec forest() :: forest()
    defrust(forest(), do: [shrink(sample()), grow(sample())])
  end

  defmodule OptionMethodsCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @typep index :: %{required(:children) => HashMap.t(R.u32(), R.vec(R.u32()))}

    @spec children_of(R.ref(index(), R.lifetime(:a)), R.u32()) ::
            R.slice(R.u32(), R.lifetime(:a))
    defrust children_of(index, id) do
      case index.children.get(ref(id)) do
        {:some, children} -> children.as_slice()
        :none -> ref([])
      end
    end

    @spec first_child(R.ref(index()), R.u32()) :: R.option(R.u32())
    defrust first_child(index, id) do
      index.children.get(ref(id)) |> and_then(fn children -> children.first().copied() end)
    end

    @spec large(R.option(R.u32())) :: R.option(R.u32())
    defrust(large(value), do: value |> filter(fn value -> deref(value) > 1 end))

    @spec collect_leaves(R.ref(index()), R.u32(), R.mut_ref(R.vec(R.u32()))) :: R.unit()
    defrust collect_leaves(index, id, leaves) do
      if children_of(index, id).is_empty() do
        leaves.push(id)
      else
        for child <- children_of(index, id) do
          collect_leaves(index, deref(child), leaves)
        end
      end
    end

    @typep holder :: %{required(:items) => R.vec(R.u32()), required(:first) => R.option(R.u32())}

    @spec total(R.slice(R.u32())) :: R.u32()
    defrust(total(values), do: values.iter().sum())

    # The binding is used through option methods and a collection method, never as a value
    # of its own type.
    @spec held(R.ref(index()), R.u32()) :: R.option(holder())
    defrust held(index, id) do
      items = children_of(index, id) |> iter() |> copied() |> collect()
      first = first_child(index, id)

      if items.is_empty() or first.is_none(),
        do: nil,
        else: some(struct_literal(Holder, items: items, first: first))
    end

    @spec summed(R.ref(index()), R.u32()) :: R.u32()
    defrust(summed(index, id), do: children_of(index, id) |> to_vec() |> total())

    @spec sample() :: index()
    defrust sample() do
      children = HashMap.new()
      children.insert(1, [2, 3])
      children.insert(3, [4])
      struct_literal(Index, children: children)
    end
  end

  defmodule PrecedenceCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec logic(R.bool(), R.bool(), R.bool()) :: R.bool()
    defrust(logic(a, b, c), do: a and (b or c))

    @spec negated(R.bool(), R.bool()) :: R.bool()
    defrust(negated(a, b), do: not (a or b))

    @spec arith(R.i64(), R.i64(), R.i64()) :: R.i64()
    defrust(arith(a, b, c), do: a - (b - c) + (a + b) * c)
  end

  defmodule MutationCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @typep tally :: %{required(:seen) => R.vec(R.u32()), required(:count) => R.u32()}

    @spec checked(R.u32()) :: R.nif_result(R.u32())
    defrust(checked(value), do: if(value > 0, do: ok(value), else: err(badarg())))

    @spec ensure(R.bool()) :: R.nif_result(R.unit())
    defrust(ensure(flag), do: if(flag, do: ok(:ok), else: err(badarg())))

    @spec halves(R.slice(R.u32())) :: {R.vec(R.u32()), R.vec(R.u32())}
    defrust(halves(values),
      do: values.iter().copied().partition(fn value -> deref(value) < 10 end)
    )

    @spec split(R.slice(R.u32())) :: {R.vec(R.u32()), R.vec(R.u32())}
    defrust split(values) do
      {small, large} = halves(values)
      small.sort()
      large.reverse()
      {small, large}
    end

    @typep pair :: %{required(:swap) => R.bool(), required(:sort) => R.u32()}

    # Fields named like methods that change a vector are read, not called.
    @spec flip(pair()) :: R.bool()
    defrust(flip(pair), do: pair.swap and pair.sort > 0)

    @spec record(tally(), R.u32()) :: tally()
    defrust record(tally, value) do
      tally.seen.push(value)
      assign!(tally.count, tally.count + 1)
      tally
    end

    @spec all_checked(R.slice(R.u32())) :: R.nif_result(R.vec(R.u32()))
    defrust all_checked(values) do
      ensure(not values.is_empty())
      checked_values = Vec.new()

      for value <- values do
        checked_values.push(checked(deref(value)))
      end

      ok(checked_values)
    end

    @spec copies(R.slice(String.t())) :: R.vec(String.t())
    defrust(copies(names), do: for(name <- names.iter(), do: name.clone()))

    @spec odd(R.slice(R.u32())) :: R.vec(R.u32())
    defrust(odd(values), do: for(value <- values, rem(deref(value), 2) == 1, do: deref(value)))

    @spec tally_first(R.mut_ref(R.vec(R.u32())), R.option(R.u32())) :: R.unit()
    defrust tally_first(found, value) do
      case value do
        {:some, 0} -> :ok
        _ -> found.push(1)
      end

      case value do
        {:some, value} -> found.push(value)
        _ -> :ok
      end
    end

    @spec record_pair(R.mut_ref(R.vec(R.u32())), R.slice(R.u32())) :: R.unit()
    defrust record_pair(found, values) do
      with [first, second] <- values,
           true <- deref(first) < deref(second) do
        found.push(deref(first) + deref(second))
      end
    end

    @spec sum(R.slice(R.u32())) :: R.u32()
    defrust(sum(values), do: values.iter().sum())

    @spec doubled_sum(R.slice(R.u32())) :: R.u32()
    defrust(doubled_sum(values),
      do: sum(values.iter().map(fn value -> deref(value) * 2 end).collect())
    )
  end

  defmodule TaggedEnumCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @typep color :: %{required(:r) => R.f64(), required(:a) => R.f64()}
    @typep literal ::
             R.enum(
               float: [R.f64()],
               boolean: [R.bool()],
               text: [String.t()],
               color: [color()],
               missing: []
             )
    @typep operation :: %{required(:operator) => R.u32(), required(:operands) => R.vec(formula())}
    @typep formula :: R.enum(literal: [literal()], alias: [R.u32()], operation: [operation()])

    @typep clone_path ::
             R.hashable(%{required(:root) => R.u32(), required(:path) => R.vec(R.u32())})
    @typep node_id :: R.hashable(R.enum(source: [R.u32()], clone: [clone_path()]))

    @spec positions(R.vec(node_id())) :: HashMap.t(node_id(), R.usize())
    defrust positions(ids) do
      ids
      |> into_iter()
      |> enumerate()
      |> map(fn {position, id} -> {id, position} end)
      |> collect()
    end

    @spec halve(literal()) :: literal()
    defrust halve(value) do
      case value do
        {:float, number} -> {:float, number / 2.0}
        {:color, color} -> {:color, %{color | a: color.a / 2.0}}
        :missing -> :missing
        other -> other
      end
    end

    @spec depth(R.ref(formula())) :: R.usize()
    defrust depth(formula) do
      case formula do
        {:operation, operation} ->
          1 +
            (operation.operands.iter().map(fn operand -> depth(operand) end).max()
             |> unwrap_or(0))

        _ ->
          0
      end
    end

    @spec sample() :: formula()
    defrust sample() do
      nested = struct_literal(Operation, operator: 2, operands: [{:alias, 1}])

      {:operation,
       struct_literal(Operation,
         operator: 1,
         operands: [{:literal, {:float, 2.0}}, {:operation, nested}, {:alias, 7}]
       )}
    end
  end

  defmodule CaptureIndexCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec double(R.i64()) :: R.i64()
    defrust(double(value), do: value * 2)

    @spec doubled(R.vec(R.i64())) :: R.vec(R.i64())
    defrust(doubled(values), do: values |> into_iter() |> map(&double/1) |> collect())

    @spec shifted(R.vec(R.i64())) :: R.vec(R.i64())
    defrust(shifted(values), do: values |> into_iter() |> map(&(&1 + 1)) |> collect())

    @spec second(R.vec(R.i64())) :: R.i64()
    defrust(second(values), do: values[1])

    @spec lookup(HashMap.t(R.i64(), R.i64()), R.i64()) :: R.i64()
    defrust(lookup(table, key), do: table[key])

    @spec tripled(R.vec(R.i64())) :: R.vec(R.i64())
    defrust(tripled(values), do: Enum.map(values, &(&1 * 3)))

    @spec offsets(R.vec(R.i64()), R.i64()) :: R.vec(R.i64())
    defrust(offsets(values, value), do: Enum.map(values, &(&1 + value)))

    @spec counts(R.ref(%{String.t() => R.i64()}), R.vec(String.t())) :: R.vec(R.i64())
    defrust(counts(stock, names), do: for(name <- names, do: stock[name]))
  end

  defmodule ClosureStructUpdateCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @typep item :: %{required(:name) => String.t(), required(:count) => integer()}

    @spec restock(R.vec(item()), integer()) :: R.vec(item())
    defrust(restock(items, extra),
      do: for(item <- items, item.count > 0, do: %{item | count: item.count + extra})
    )

    @spec renamed(R.vec({String.t(), item()})) :: R.vec(item())
    defrust(renamed(pairs), do: for({name, item} <- pairs, do: %{item | name: name}))

    @spec grid(R.vec(item()), R.vec(integer())) :: R.vec(item())
    defrust(grid(items, counts),
      do: for(item <- items, count <- counts, do: %{item | count: count})
    )

    @spec copies(item(), R.vec(integer())) :: R.vec(item())
    defrust(copies(item, counts), do: Enum.map(counts, fn count -> %{item | count: count} end))

    @spec total(R.vec(item())) :: integer()
    defrust(total(items),
      do: Enum.reduce(items, 0, fn item, sum -> sum + %{item | count: 1}.count end)
    )
  end

  defmodule WrapperComparisonCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec matching(R.option(R.u32()), R.option(R.u32())) :: R.option(R.bool())
    defrust matching(left, right) do
      if left == some(3) do
        some(true)
      else
        some(left == right)
      end
    end

    @spec next(R.option(R.u32())) :: R.option(R.u32())
    defrust(next(value), do: some(value + 1))
  end

  defmodule MutationChainCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec group(R.vec({R.u32(), R.u32()})) :: HashMap.t(R.u32(), R.vec(R.u32()))
    defrust group(pairs) do
      groups = HashMap.new()

      for {key, value} <- pairs do
        groups.entry(key).or_default().push(value)
      end

      groups
    end

    @spec evens(R.vec(R.u32())) :: R.vec(R.u32())
    defrust evens(values) do
      values
      |> into_iter()
      |> fold(Vec.new(), fn found, value ->
        if rem(value, 2) == 0 do
          found.push(value)
        end

        found
      end)
    end
  end

  defmodule LifetimeCase do
    use RustQ.Meta
    alias RustQ.Type, as: R

    @spec pick(
            R.ref(R.vec(R.u32()), R.lifetime(:a)),
            R.ref(R.vec(R.u32()), R.lifetime(:a)),
            R.bool()
          ) :: R.ref(R.u32(), R.lifetime(:a))
    defrust(pick(left, right, first), do: if(first, do: ref(left[0]), else: ref(right[0])))
  end

  test "Meta returns rendered items" do
    functions = MetaAST.functions(RustQ.Meta.GeneratedCase)
    item = MetaAST.function!(RustQ.Meta.GeneratedCase, :draw_save)

    assert Enum.any?(functions, &(&1.name == :draw_save))
    assert RustQ.Rust.to_fragment(item) =~ "fn draw_save"

    assert_raise ArgumentError, fn ->
      MetaAST.function!(RustQ.Meta.GeneratedCase, :missing)
    end

    assert_raise ArgumentError, ~r/no compiled defrust function metadata/, fn ->
      MetaAST.functions(__MODULE__)
    end
  end

  test "defrust lowers zero-arity closures" do
    defmodule ZeroArityClosureCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec value() :: R.i64()
      defrust value() do
        get_or_init(fn -> 42 end)
      end
    end

    source = ZeroArityClosureCase.__rustq_source__()
    assert source =~ "get_or_init(|| 42)"
  end

  test "defrust lowers arrays and indexed assignment" do
    defmodule ArrayIndexCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec fill(R.u8()) :: R.nif_result(R.unit())
      defrust fill(value) do
        values = array([cast(0, :u8), cast(0, :u8)])
        index = cast(0, :usize)
        assign!(index(values, index), value)
        :ok
      end
    end

    source = ArrayIndexCase.__rustq_source__()
    assert source =~ "let mut values = [0 as u8, 0 as u8];"
    assert source =~ "values[index] = value;"
  end

  test "defrust lowers structural Rust enum variants" do
    defmodule EnumVariantCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec one(R.raw(:SkipFn)) :: R.raw(:KiwiSkipKind)
      defrust one(skip) do
        enum_variant(KiwiSkipKind, :one, skip)
      end

      @spec bytes() :: R.raw(:KiwiSkipKind)
      defrust bytes() do
        enum_variant(KiwiSkipKind, :bytes)
      end
    end

    source = EnumVariantCase.__rustq_source__()

    assert source =~ "KiwiSkipKind::One(skip)"
    assert source =~ "KiwiSkipKind::Bytes"
  end

  test "defrust lowers structural Rust struct literals" do
    defmodule StructLiteralCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec cubic(R.f64(), R.f64()) :: R.path(:CubicResampler)
      defrust cubic(b, c) do
        struct_literal(CubicResampler, b: cast(b, :f32), c: cast(c, :f32))
      end
    end

    source = StructLiteralCase.__rustq_source__()
    assert source =~ "CubicResampler {"
    assert source =~ "b: b as f32"
    assert source =~ "c: c as f32"
  end

  test "defrust lowers bitwise helper calls" do
    defmodule BitwiseHelperCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec red(R.u32()) :: R.u8()
      defrust red(rgba) do
        Bitwise.band(Bitwise.bsr(rgba, 24), 0xFF)
        |> cast(:u8)
      end
    end

    source = BitwiseHelperCase.__rustq_source__()
    assert source =~ "(rgba >> 24 & 255) as u8"
  end

  test "defrust lowers arithmetic operators" do
    defmodule ArithmeticCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec scale(R.f32(), R.f32()) :: R.f32()
      defrust scale(x, y) do
        x + y * 2.0 - x / 4.0
      end
    end

    source = ArithmeticCase.__rustq_source__()
    assert source =~ "x + y * 2.0 - x / 4.0"
  end

  test "defrust lowers cond, unary operators, div, and rem" do
    defmodule CondOperatorCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec classify(R.i64()) :: R.i64()
      defrust classify(value) do
        cond do
          value < 0 -> -1
          rem(value, 2) == 0 -> div(value, 2)
          true -> +value
        end
      end

      @spec invert(boolean()) :: boolean()
      defrust(invert(value), do: not value)
    end

    classify = rust_source!(CondOperatorCase, :classify)
    invert = rust_source!(CondOperatorCase, :invert)

    assert classify =~ "if value < 0"
    assert classify =~ "value % 2 == 0"
    assert classify =~ "value / 2"
    assert invert =~ "fn invert(value: bool) -> bool"
    assert invert =~ "!value"
    assert RustQ.valid?(rust_source!(CondOperatorCase), "cond_operators.rs")
  end

  test "defrust lowers common Enum operations to Rust iterators" do
    defmodule EnumPipelineCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec product([integer()]) :: integer()
      defrust(product(values),
        do: Enum.reduce(values, 1, fn value, product -> product * value end)
      )

      @spec positives([integer()]) :: [integer()]
      defrust(positives(values), do: Enum.filter(values, fn value -> value > 0 end))

      @spec duplicates([integer()]) :: [integer()]
      defrust(duplicates(values), do: Enum.flat_map(values, fn value -> [value, value] end))

      @spec has_positive(R.vec(R.i64())) :: boolean()
      defrust(has_positive(values), do: Enum.any?(values, fn value -> value > 0 end))
    end

    assert rust_source!(EnumPipelineCase, :product) =~
             ".into_iter().fold(1, |product, value| product * value)"

    positives = rust_source!(EnumPipelineCase, :positives)
    assert positives =~ ".filter_map(|value| if value > 0"
    assert positives =~ "Some(value)"

    assert rust_source!(EnumPipelineCase, :duplicates) =~
             ".flat_map(|value| vec![value, value]).collect::<Vec<i64>>()"

    assert rust_source!(EnumPipelineCase, :has_positive) =~
             ".into_iter().any(|value| value > 0)"

    assert RustQ.valid?(rust_source!(EnumPipelineCase), "enum_pipelines.rs")
  end

  test "defrust lowers supported remote calls in Elixir pipelines" do
    defmodule RemotePipelineCase do
      use RustQ.Meta

      @spec positive_square_sum([integer()]) :: integer()
      defrust positive_square_sum(values) do
        values
        |> Enum.filter(fn value -> value > 0 end)
        |> Enum.map(fn value -> value * value end)
        # credo:disable-for-next-line ExSlop.Check.Refactor.ExplicitSumReduce
        |> Enum.reduce(0, fn value, total -> value + total end)
      end

      @spec count_positive([integer()]) :: integer()
      defrust count_positive(values) do
        values
        |> Enum.filter(fn value -> value > 0 end)
        # credo:disable-for-next-line Credo.Check.Refactor.FilterCount
        |> Enum.count()
      end

      @spec has_square([integer()], integer()) :: boolean()
      defrust has_square(values, expected) do
        values
        |> Enum.map(fn value -> value * value end)
        |> Enum.any?(fn value -> value == expected end)
      end

      @spec first_or([integer()], integer()) :: integer()
      defrust(first_or(values, default), do: values |> List.first(default))

      @spec trimmed(String.t()) :: String.t()
      defrust(trimmed(value), do: value |> String.trim())
    end

    positive_square_sum = rust_source!(RemotePipelineCase, :positive_square_sum)
    count_positive = rust_source!(RemotePipelineCase, :count_positive)
    has_square = rust_source!(RemotePipelineCase, :has_square)

    assert positive_square_sum =~
             ~r/filter_map.*collect::<Vec<i64>>.*\.map.*collect::<Vec<i64>>.*\.fold/s

    assert count_positive =~ ~r/filter_map.*collect::<Vec<i64>>.*\.len\(\) as i64/s
    assert has_square =~ ~r/\.map.*collect::<Vec<i64>>.*\.any/s
    assert rust_source!(RemotePipelineCase, :first_or) =~ ".into_iter().next().unwrap_or(default)"
    assert rust_source!(RemotePipelineCase, :trimmed) =~ ".trim().to_string()"
    assert RustQ.valid?(rust_source!(RemotePipelineCase), "remote_pipeline_case.rs")
  end

  test "defrust lowers Elixir pipelines to Rust method, operator, and cast chains" do
    defmodule PipelineCastCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec alpha(OpacityOpts.t()) :: R.u8()
      defrust alpha(opts) do
        opts.opacity.unwrap_or(1.0)
        |> clamp(0.0, 1.0)
        |> Kernel.*(255.0)
        |> round()
        |> cast(:u8)
      end
    end

    source = PipelineCastCase.__rustq_source__()
    assert source =~ "opts.opacity.unwrap_or(1.0).clamp(0.0, 1.0)"
    assert source =~ "* 255.0"
    assert source =~ ".round() as u8"
  end

  test "defrust cast accepts RustQ type markers" do
    defmodule TypeMarkerCastCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec widen(R.u8()) :: R.u32()
      defrust widen(value) do
        cast(value, R.u32())
      end
    end

    source = TypeMarkerCastCase.__rustq_source__()
    assert source =~ "value as u32"
  end

  test "defrust lowers comparison operators" do
    defmodule ComparisonCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec positive(R.f32()) :: R.nif_result(R.unit())
      defrust positive(radius) do
        if radius > 0.0 do
          use_positive(radius)
        else
          use_zero()
        end

        :ok
      end
    end

    source = ComparisonCase.__rustq_source__()
    assert source =~ "if radius > 0.0"
  end

  test "defrust expands ordinary Elixir helper macros before lowering" do
    defmodule MacroBodyCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defmacro with_saved_canvas(do: body) do
        quote do
          var!(canvas).save()
          unquote(body)
          var!(canvas).restore()
        end
      end

      @spec draw(R.ref(Canvas.t())) :: R.nif_result(R.unit())
      defrust draw(canvas) do
        with_saved_canvas do
          canvas.translate({1.0, 2.0})
        end

        :ok
      end
    end

    source = MacroBodyCase.__rustq_source__()
    assert source =~ "canvas.save();"
    assert source =~ "canvas.translate((1.0, 2.0));"
    assert source =~ "canvas.restore();"
  end

  test "defrustmod maps alias calls to Rust module paths" do
    defmodule ModuleMappedCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defrustmod(GeneratedOpts, as: :generated_opts)

      @spec decode(term()) :: R.nif_result(R.unit())
      defrust decode(opts) do
        GeneratedOpts.decode_path_opts(ref(opts))
      end
    end

    source = ModuleMappedCase.__rustq_source__()
    assert source =~ "generated_opts::decode_path_opts(&opts)"
  end

  test "defrustmod maps nested alias constant paths" do
    defmodule NestedModuleConstantCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defrustmod(SkiaSafe.ArcSize, as: [:skia_safe, :path_builder, :ArcSize])

      @spec large() :: R.nif_result(R.path(:ArcSize))
      defrust large() do
        {:ok, SkiaSafe.ArcSize.Large}
      end
    end

    source = NestedModuleConstantCase.__rustq_source__()

    assert source =~ "Ok(skia_safe::path_builder::ArcSize::Large)"
  end

  test "defrustmod groups nested defrust declarations" do
    defmodule NestedModuleCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defrustmod GeneratedHelpers, as: :generated_helpers do
        @spec save(R.ref(Canvas.t())) :: R.nif_result(R.unit())
        defrust save(canvas) do
          canvas.save()
          :ok
        end
      end
    end

    source = NestedModuleCase.__rustq_source__()
    assert source =~ "mod generated_helpers"
    assert source =~ "fn save(canvas: &Canvas) -> NifResult<()>"
    assert source =~ "canvas.save();"
  end

  test "lowers plural module alias calls as snake_case Rust modules" do
    defmodule AutomaticModuleAliasCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec atom_call() :: R.nif_result(atom())
      defrust atom_call() do
        Atoms.fill()
      end
    end

    source = AutomaticModuleAliasCase.__rustq_source__()
    assert source =~ "atoms::fill()"
  end

  test "lowers zero-arity alias calls from defrust as Rust calls" do
    defmodule AliasCallCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec atom_call() :: R.nif_result(atom())
      defrust atom_call() do
        Atoms.args()
      end

      @spec nil_atom_call() :: R.nif_result(atom())
      defrust nil_atom_call() do
        Atoms.nil()
      end
    end

    source = AliasCallCase.__rustq_source__()
    assert source =~ "atoms::args()"
    assert source =~ "atoms::nil()"
  end

  test "lowers simple for comprehensions to Rust for loops" do
    defmodule ForComprehensionCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec push_pairs(R.vec({String.t(), R.u32()})) :: R.nif_result(R.unit())
      defrust push_pairs(pairs) do
        for {name, count} <- pairs do
          push_pair(name, count)
        end

        :ok
      end
    end

    source = ForComprehensionCase.__rustq_source__()

    assert source =~ "for (name, count) in pairs"
    assert source =~ "push_pair(name, count);"
  end

  test "lowers comprehensions with filters, refutable patterns, and nested generators" do
    source = FilteredComprehensionCase.__rustq_source__() |> String.replace(~r/\s+/, " ")

    assert source =~
             "values .into_iter() .filter_map(|item| match item { value if value % 2 == 0 => Some(value), _ => None, }) .map(|value| value * 10) .collect()"

    assert source =~ "match item { Some(value) => Some(value), _ => None, }) .collect()"
    assert source =~ "left.into_iter() .flat_map(|x|"
    assert source =~ "y if x < y => Some(y)"
    assert source =~ ".map(|y| (x, y))"
    assert source =~ "pairs.into_iter().collect()"
  end

  @tag :tmp_dir
  test "compiled comprehensions return what Elixir comprehensions return", %{tmp_dir: dir} do
    source =
      FilteredComprehensionCase.__rustq_source__() <>
        LoopComprehensionCase.__rustq_source__() <>
        """
        fn main() {
            println!("{:?}", evens(vec![1, 2, 3, 4]));
            println!("{:?}", present(vec![Some(1), None, Some(3)]));
            println!("{:?}", pairs(vec![1, 2], vec![1, 2, 3]));
            let mut keyed: Vec<_> = by_key(vec![(1, 10), (2, 20)]).into_iter().collect();
            keyed.sort();
            println!("{:?}", keyed);
            println!("{:?}", positive(vec![Some(4), None, Some(-2), Some(5)]));
        }
        """

    path = Path.join(dir, "comprehensions.rs")
    executable = Path.join(dir, "comprehensions")
    File.write!(path, "use std::collections::HashMap;\n" <> source)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {output, 0} = System.cmd(executable, [])

    expected = [
      for(value <- [1, 2, 3, 4], rem(value, 2) == 0, do: value * 10),
      for({:some, value} <- [{:some, 1}, nil, {:some, 3}], do: value),
      for(x <- [1, 2], y <- [1, 2, 3], x < y, do: {x, y}),
      for({key, value} <- [{1, 10}, {2, 20}], into: %{}, do: {key, value}) |> Enum.sort(),
      for({:some, value} <- [{:some, 4}, nil, {:some, -2}, {:some, 5}], value > 0, do: value)
    ]

    assert String.split(output, "\n", trim: true) == [
             "[20, 40]",
             "[1, 3]",
             "[(1, 2), (1, 3), (2, 3)]",
             "[(1, 10), (2, 20)]",
             "[4, 5]"
           ]

    assert expected == [[20, 40], [1, 3], [{1, 2}, {1, 3}, {2, 3}], [{1, 10}, {2, 20}], [4, 5]]
  end

  test "lowers effect comprehensions with refutable patterns and filters to loops" do
    source = LoopComprehensionCase.__rustq_source__()
    assert source =~ "let mut found = Vec::new();"
    assert source =~ "for __rustq_item in values"
    assert source =~ "if let Some(value) = __rustq_item"
    assert source =~ "if value > 0"
  end

  test "names predicates without their question mark and escapes reserved words" do
    defmodule RustNamesCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec positive?(R.i64()) :: R.bool()
      defrust(positive?(value), do: value > 0)

      @spec shift(R.i64()) :: R.i64()
      defrust shift(override) do
        type = override + 1
        if positive?(type), do: type, else: 0
      end
    end

    source = RustNamesCase.__rustq_source__()
    assert MetaAST.function!(RustNamesCase, :positive?).name == :positive?
    assert source =~ "fn positive(value: i64) -> bool"
    assert source =~ "fn shift(r#override: i64) -> i64"
    assert source =~ "let r#type = r#override + 1;"
    assert source =~ "if positive(r#type)"
    assert RustQ.valid?(source, "rust_names.rs")
  end

  test "rejects functions whose Rust names collide" do
    assert_raise ArgumentError,
                 ~r/:ready\? and :ready both become the Rust function ready|:ready and :ready\? both become the Rust function ready/,
                 fn ->
                   defmodule RustNameCollisionCase do
                     use RustQ.Meta
                     alias RustQ.Type, as: R

                     @spec ready(R.i64()) :: R.bool()
                     defrust(ready(value), do: value > 0)

                     @spec ready?(R.i64()) :: R.bool()
                     defrust(ready?(value), do: value > 1)
                   end
                 end
  end

  @tag :tmp_dir
  test "updates structs, including recursive ones", %{tmp_dir: dir} do
    source = StructUpdateCase.__rustq_source__()
    assert source =~ "..node"

    program =
      """
      #{source}
      fn main() {
          let tree = relabel(sample(), 7);
          println!("{} {} {}", tree.label, tree.children[0].label, tree.children[0].scale);
      }
      """

    path = Path.join(dir, "struct_update.rs")
    executable = Path.join(dir, "struct_update")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"7 2 2\n", 0} = System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "uses the types its callable modules declare", %{tmp_dir: dir} do
    source = ImportedTypeCase.__rustq_source__()
    refute source =~ "struct Tree"
    assert source =~ "pub type Forest = Vec<Tree>;"

    program =
      """
      #{StructUpdateCase.__rustq_source__()}
      #{source}
      fn main() {
          let forest = forest();
          println!("{} {}", forest[0].scale, forest[1].scale);
          println!("{} {}", size_label(size(&forest[0])), size_label(size(&forest[1])));
          println!("{}", size_label(large().size));
      }
      """

    path = Path.join(dir, "imported_types.rs")
    executable = Path.join(dir, "imported_types")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"0.5 2\n1 2\n2\n", 0} = System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "types option and map methods and runs unit bodies for their effects", %{tmp_dir: dir} do
    source = OptionMethodsCase.__rustq_source__()
    refute source =~ "Some(index.children.get"
    assert source =~ "None => &[],"

    program =
      """
      use std::collections::HashMap;
      #{source}
      fn main() {
          let index = sample();
          let mut leaves = Vec::new();
          collect_leaves(&index, 1, &mut leaves);
          println!("{:?} {:?} {:?} {:?}", leaves, first_child(&index, 1), large(Some(1)), children_of(&index, 9));
          println!("{:?} {:?} {}", held(&index, 1).map(|h| h.items), held(&index, 4).is_none(), summed(&index, 1));
      }
      """

    path = Path.join(dir, "option_methods.rs")
    executable = Path.join(dir, "option_methods")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"[2, 4] Some(2) None []\nSome([2, 3]) true 5\n", 0} = System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "marks changed bindings mut and propagates pushed results", %{tmp_dir: dir} do
    source = MutationCase.__rustq_source__()
    assert source =~ "fn flip(pair: Pair) -> bool"
    assert source =~ "names.iter().cloned().collect()"
    assert source =~ "values\n        .iter()\n        .filter_map"
    refute source =~ ".iter()\n        .into_iter()"
    assert source =~ "if let Some(value) = value {"
    assert source =~ "if let [first, second] = values {"
    assert source =~ "if *first < *second {"

    program =
      """
      mod rustler {
          #[derive(Debug)]
          pub enum Error { BadArg }
      }
      type NifResult<T> = Result<T, rustler::Error>;
      #{MutationCase.__rustq_source__()}
      fn main() {
          let tally = record(Tally { seen: vec![], count: 0 }, 4);
          let mut found = vec![];
          tally_first(&mut found, Some(3));
          tally_first(&mut found, Some(0));
          record_pair(&mut found, &[1, 2]);
          record_pair(&mut found, &[2, 1]);
          println!("{:?} {:?} {:?}", found, copies(&["a".to_string()]), odd(&[1, 2, 3]));
          println!("{:?} {:?} {} {}", split(&[30, 2, 12, 1]), tally.seen, tally.count, doubled_sum(&[1, 2]));
          println!("{:?} {:?} {:?}", all_checked(&[1, 2]), all_checked(&[1, 0]).is_err(), all_checked(&[]).is_err());
      }
      """

    path = Path.join(dir, "mutation.rs")
    executable = Path.join(dir, "mutation")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"[1, 3, 0, 3] [\"a\"] [1, 3]\n([1, 2], [12, 30]) [4] 1 6\nOk([1, 2]) true true\n", 0} =
             System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "builds and matches Rust enums from tagged tuples", %{tmp_dir: dir} do
    program =
      """
      use std::collections::HashMap;
      #{TaggedEnumCase.__rustq_source__()}
      fn main() {
          println!("{:?} {:?} {}", halve(Literal::Float(3.0)), halve(Literal::Missing), depth(&sample()));
          let clone = NodeId::Clone(ClonePath { root: 1, path: vec![2, 3] });
          println!("{:?}", positions(vec![NodeId::Source(1), clone.clone()]).get(&clone));
      }
      """

    path = Path.join(dir, "tagged_enum.rs")
    executable = Path.join(dir, "tagged_enum")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"Float(1.5) Missing 2\nSome(1)\n", 0} = System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "keeps the grouping of nested operators", %{tmp_dir: dir} do
    program =
      """
      #{PrecedenceCase.__rustq_source__()}
      fn main() {
          println!("{} {} {}", logic(false, true, true), negated(false, true), arith(5, 3, 1, ));
      }
      """

    path = Path.join(dir, "precedence.rs")
    executable = Path.join(dir, "precedence")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"false false 11\n", 0} = System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "matches constants, booleans, and rebound names", %{tmp_dir: dir} do
    source = PatternPathCase.__rustq_source__()
    assert source =~ "Some(kinds::FANCY) => 1"
    assert source =~ "true => Some(value * 2)"
    assert source =~ "_ => None"
    refute source =~ "__rustq_with_value"
    assert source =~ "(&[kinds::PLAIN, kinds::FANCY]).contains(&value)"

    program =
      """
      mod kinds {
          pub const PLAIN: u32 = 0;
          pub const FANCY: u32 = 3;
      }
      #{source}
      fn main() {
          println!("{} {} {}", label(Some(3)), label(Some(0)), label(None));
          println!("{:?} {:?} {:?}", checked(Some(4), true), checked(Some(4), false), checked(None, true));
          println!("{} {}", listed(3), listed(7));
          println!("{} {} {}", pair_label(Some(3), Some(9)), pair_label(None, Some(0)), pair_label(None, None));
          println!("{:?} {:?} {:?} {:?}", doubled(2), doubled(-1), bumped(Some(1)), bumped(None));
          println!("{:?}", other_kinds(vec![Some(3), None, Some(0)], 3));
      }
      """

    path = Path.join(dir, "patterns.rs")
    executable = Path.join(dir, "patterns")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {output, 0} = System.cmd(executable, [])

    assert String.split(output, "\n", trim: true) == [
             "1 2 0",
             "Some(8) None None",
             "true false",
             "9 100 0",
             "Ok(4) Err(0) Some(2) None",
             "[None, Some(0)]"
           ]
  end

  @tag :tmp_dir
  test "captures functions and indexes lists and maps", %{tmp_dir: dir} do
    source = CaptureIndexCase.__rustq_source__()
    assert source =~ "values.into_iter().map(double).collect()"
    assert source =~ "table[&key]"
    assert source =~ "values.into_iter().map(|value| value * 3)"
    assert source =~ "values.into_iter().map(|value_| value_ + value)"
    assert source =~ "fn counts(stock: &HashMap<String, i64>, names: Vec<String>) -> Vec<i64>"
    assert source =~ "stock[&name]"

    program =
      """
      use std::collections::HashMap;
      #{source}
      fn main() {
          println!("{:?} {:?} {}", doubled(vec![1, 2]), shifted(vec![1, 2]), second(vec![5, 6]));
          println!("{}", lookup(HashMap::from([(1, 10)]), 1));
          println!("{:?} {:?}", tripled(vec![1, 2]), offsets(vec![1, 2], 10));
          println!("{:?}", counts(&HashMap::from([("a".to_string(), 7)]), vec!["a".to_string()]));
      }
      """

    path = Path.join(dir, "captures.rs")
    executable = Path.join(dir, "captures")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {output, 0} = System.cmd(executable, [])

    assert String.split(output, "\n", trim: true) == [
             "[2, 4] [2, 3] 6",
             "10",
             "[3, 6] [11, 12]",
             "[7]"
           ]
  end

  @tag :tmp_dir
  test "updates structs that closures and comprehensions are given", %{tmp_dir: dir} do
    source = ClosureStructUpdateCase.__rustq_source__()

    assert source =~ "..item\n"
    assert source =~ "Item { name, ..item }"
    assert source =~ "counts.iter().cloned().map(|count| Item { count, ..item.clone() })"
    assert source =~ "..item.clone()"

    program =
      """
      #{source}
      fn main() {
          let item = Item { name: "a".to_string(), count: 1 };
          println!("{:?}", restock(vec![item.clone(), Item { name: "b".to_string(), count: 0 }], 2));
          println!("{:?}", renamed(vec![("c".to_string(), item.clone())]));
          println!("{:?}", grid(vec![item.clone()], vec![5, 6]));
          println!("{:?} {}", copies(item.clone(), vec![7]), total(vec![item.clone(), item]));
      }
      """

    path = Path.join(dir, "closure_struct_update.rs")
    executable = Path.join(dir, "closure_struct_update")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {output, 0} = System.cmd(executable, [])

    assert String.split(output, "\n", trim: true) == [
             ~s([Item { name: "a", count: 3 }]),
             ~s([Item { name: "c", count: 1 }]),
             ~s([Item { name: "a", count: 5 }, Item { name: "a", count: 6 }]),
             ~s([Item { name: "a", count: 7 }] 2)
           ]
  end

  test "compares options without propagating them" do
    source = WrapperComparisonCase.__rustq_source__()

    assert source =~ "if left == Some(3)"
    assert source =~ "Some(left == right)"
    assert source =~ "Some(value? + 1)"
    assert RustQ.valid?(source, "wrapper_comparison.rs")
  end

  @tag :tmp_dir
  test "marks variables changed through method chains and closure arguments mut", %{tmp_dir: dir} do
    source = MutationChainCase.__rustq_source__()
    assert source =~ "let mut groups: HashMap<u32, Vec<u32>> = HashMap::new();"
    assert source =~ "|mut found, value|"

    program =
      """
      #![deny(warnings)]
      use std::collections::HashMap;
      #{source}
      fn main() {
          let groups = group(vec![(1, 10), (1, 11), (2, 20)]);
          println!("{:?} {:?} {:?}", groups[&1], groups[&2], evens(vec![1, 2, 3, 4]));
      }
      """

    path = Path.join(dir, "mutation.rs")
    executable = Path.join(dir, "mutation")
    File.write!(path, program)

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"[10, 11] [20] [2, 4]\n", 0} = System.cmd(executable, [])
  end

  @tag :tmp_dir
  test "declares the lifetimes references name", %{tmp_dir: dir} do
    source = LifetimeCase.__rustq_source__()

    assert source =~
             "fn pick<'a>(left: &'a Vec<u32>, right: &'a Vec<u32>, first: bool) -> &'a u32"

    path = Path.join(dir, "lifetimes.rs")
    executable = Path.join(dir, "lifetimes")

    File.write!(
      path,
      source <>
        ~s|fn main() { println!("{} {}", pick(&vec![1], &vec![2], true), pick(&vec![1], &vec![2], false)); }|
    )

    assert {_, 0} =
             System.cmd("rustc", ["--edition", "2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"1 2\n", 0} = System.cmd(executable, [])
  end

  test "marks mutable lets inside if branches" do
    defmodule IfBranchMutationCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec collect_if(R.bool(), R.vec(R.f64())) :: R.nif_result(R.unit())
      defrust collect_if(enabled, values) do
        if enabled do
          mapped = Vec.with_capacity(values.len())

          for value <- values do
            mapped.push(cast(value, :f32))
          end

          use_values(mapped.as_slice())
        end

        :ok
      end
    end

    source = IfBranchMutationCase.__rustq_source__()
    assert source =~ "let mut mapped = Vec::with_capacity(values.len());"
  end

  test "keeps tuple pattern lets through mutability inference" do
    defmodule TupleLetCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec pair(term()) :: R.nif_result(R.unit())
      defrust pair(term) do
        {left, right} = decode_as!(term, {R.u8(), R.u8()})
        use_pair(left, right)
        :ok
      end
    end

    source = TupleLetCase.__rustq_source__()
    assert source =~ "let (left, right) = term.decode::<(u8, u8)>()?;"
  end

  test "marks assign bang targets as mutable lets" do
    defmodule AssignBangMutationCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec toggle() :: R.nif_result(R.bool())
      defrust toggle() do
        flag = true
        assign!(flag, false)
        {:ok, flag}
      end
    end

    source = AssignBangMutationCase.__rustq_source__()
    assert source =~ "let mut flag = true;"
    assert source =~ "flag = false;"
  end

  test "renders assign bang arithmetic as compound assignment" do
    defmodule AssignBangCompoundCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec count() :: R.usize()
      defrust count() do
        count = 2
        assign!(count, count + 1)
        count
      end
    end

    source = AssignBangCompoundCase.__rustq_source__()
    assert source =~ "let mut count = 2;"
    assert source =~ "count += 1;"
  end

  test "renders assign bang Bitwise operations as compound assignment" do
    defmodule AssignBangBitwiseCompoundCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec masked(R.u32()) :: R.u32()
      defrust masked(mask) do
        value = 255
        assign!(value, Bitwise.band(value, mask))
        value
      end
    end

    source = AssignBangBitwiseCompoundCase.__rustq_source__()
    assert source =~ "value &= mask;"
  end

  test "lowers statement option cases with unit none branch to if let" do
    defmodule OptionCaseIfLetStatementCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec attr(R.option(R.path(:String)), R.usize()) ::
              R.raw(:"Option<(&'static str, String)>")
      defrust attr(name, index) do
        cursor = 0

        case name.as_ref() do
          {:some, value} ->
            if index == cursor do
              return!(some({"name", value.clone()}))
            end

            assign!(cursor, cursor + 1)

          :none ->
            :ok
        end

        nil
      end
    end

    source = OptionCaseIfLetStatementCase.__rustq_source__()
    assert source =~ "if let Some(value) = name.as_ref()"
    assert source =~ "cursor += 1;"
    refute source =~ "match name.as_ref()"
  end

  test "builds typed Rustler decode expressions from defrust valid Elixir" do
    defmodule DecodeTermsCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode_terms(term()) :: R.nif_result(R.vec(term()))
      defrust decode_terms(term) do
        decode_as!(term, R.vec(term()))
      end
    end

    source = DecodeTermsCase.__rustq_source__()
    assert source =~ "fn decode_terms<'a>(term: Term<'a>) -> NifResult<Vec<Term<'a>>>"
    assert source =~ "term.decode::<Vec<Term<'a>>>()?"
  end

  test "lowers integer match patterns from defrust valid Elixir" do
    defmodule IntegerMatchCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode(R.i64()) :: R.nif_result(R.unit())
      defrust decode(op) do
        case op do
          1 -> draw_move()
          2 -> draw_line()
          _ -> :ok
        end

        :ok
      end
    end

    source = IntegerMatchCase.__rustq_source__()

    assert source =~ "1 =>"
    assert source =~ "2 =>"
  end

  test "lowers Rust tuple field access from defrust valid Elixir" do
    defmodule TupleFieldCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec first(R.raw(:Tuple1)) :: R.nif_result(R.i64())
      defrust first(tuple) do
        {:ok, tuple_field(tuple, 0)}
      end
    end

    source = TupleFieldCase.__rustq_source__()

    assert source =~ "Ok(tuple.0)"
  end

  test "lowers nested tuple decode probe matches" do
    defmodule NestedTupleDecodeProbeCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec probe(term()) :: R.nif_result(R.unit())
      defrust probe(term) do
        case decode_as(term, {R.atom(), {R.f64(), R.f64()}}) do
          {:ok, {tag, {x, y}}} -> handle(tag, x, y)
          {:error, _reason} -> :ok
        end

        :ok
      end
    end

    source = NestedTupleDecodeProbeCase.__rustq_source__()
    assert source =~ "Ok((tag, (x, y))) =>"
  end

  test "builds typed Rustler decode result probes from defrust valid Elixir" do
    defmodule DecodeResultProbeCase do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec probe(term()) :: R.nif_result(R.unit())
      defrust probe(term) do
        case decode_as(term, {R.i64(), R.f64()}) do
          {:ok, {op, value}} -> handle(op, value)
          {:error, _reason} -> :ok
        end

        :ok
      end
    end

    source = DecodeResultProbeCase.__rustq_source__()

    assert source =~ "match term.decode::<(i64, f64)>()"
    assert source =~ "Ok((op, value)) =>"
    assert source =~ "Err(_reason) =>"
  end

  test "native AST renderer emits Rust through syn" do
    [draw_save | _] = MetaAST.functions(Generated)

    assert Nif.render_ast(draw_save) =~
             "fn draw_save(canvas: &Canvas) -> NifResult<()>"

    assert Nif.render_ast(draw_save) =~ "canvas.save();"
  end

  test "generated items remain structural RustQ AST" do
    assert Enum.all?(Generated.__rustq_items__(), fn item ->
             item.__struct__.__rustq_ast_category__() == :item
           end)
  end
end
