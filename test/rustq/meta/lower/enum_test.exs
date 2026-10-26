defmodule RustQ.Meta.Lower.EnumTest do
  use RustQ.Test, async: true

  defmodule Lists do
    @moduledoc "Lists used after an `Enum` call, or by values built from them."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec any_long(R.vec(String.t())) :: R.vec(String.t())
    defrust any_long(names) do
      if Enum.any?(names, fn name -> name.len() > 3 end), do: names, else: Vec.new()
    end

    @spec lengths(R.vec(String.t())) :: R.vec(R.usize())
    defrust(lengths(names), do: Enum.map(names, fn name -> name.len() end))

    @spec padded(R.vec(String.t())) :: R.vec(R.usize())
    defrust padded(names) do
      first = names.first()

      Enum.map(names, fn name ->
        name.len() + first.map(fn first -> first.len() end).unwrap_or(0)
      end)
    end

    @spec kept(R.vec(String.t())) :: {R.vec(String.t()), R.vec(String.t())}
    defrust kept(names) do
      long = Enum.filter(names, fn name -> name.len() > 3 end)
      {long, names}
    end

    @spec by_length(R.slice(String.t())) :: HashMap.t(R.usize(), R.ref(String.t()))
    defrust by_length(names) do
      for name <- names,
          {:some, length} <- [nonzero(name)],
          into: HashMap.new(),
          do: {length, name}
    end

    @spec checked(R.vec(String.t())) :: R.vec(R.bool())
    defrust(checked(names), do: Enum.map(names, fn name -> unseen(name, HashSet.new()) end))

    @spec unseen(R.ref(String.t()), R.ref(HashSet.t(String.t()))) :: R.bool()
    defrust(unseen(name, seen), do: not seen.contains(name))

    @type roster :: %{required(:names) => R.vec(String.t())}

    @spec has_long(R.ref(roster())) :: R.bool()
    defrust(has_long(roster), do: Enum.any?(roster.names, fn name -> name.len() > 3 end))

    @spec long_names(R.ref(roster())) :: R.vec(String.t())
    defrust(long_names(roster), do: for(name <- roster.names, name.len() > 3, do: name))

    @spec nonzero(R.ref(String.t())) :: R.option(R.usize())
    defrust(nonzero(name), do: if(name.is_empty(), do: nil, else: some(name.len())))

    @spec copies(R.vec(R.ref(String.t()))) :: R.vec(String.t())
    defrust(copies(names), do: Enum.map(names, fn name -> name.clone() end))

    @spec greet_all(R.slice(String.t())) :: R.unit()
    defrust greet_all(names) do
      for name <- names do
        greet(name)
      end
    end

    @spec greet(R.ref(String.t())) :: R.usize()
    defrust(greet(name), do: name.len())
  end

  defmodule Queries do
    @moduledoc "`Enum` functions beyond mapping and filtering."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec by_length([String.t()]) :: %{R.usize() => [String.t()]}
    defrust(by_length(names), do: Enum.group_by(names, fn name -> name.len() end))

    @spec indexed([String.t()]) :: [{String.t(), R.usize()}]
    defrust(indexed(names), do: Enum.with_index(names))

    @spec positions(R.slice(String.t())) :: %{String.t() => R.usize()}
    defrust positions(names) do
      for {name, index} <- Enum.with_index(names), into: HashMap.new(), do: {name.clone(), index}
    end

    @spec first_long(R.slice(String.t())) :: R.option(R.usize())
    defrust(first_long(names), do: Enum.find_index(names, fn name -> name.len() > 3 end))

    @spec first_length(R.slice(String.t())) :: R.option(R.usize())
    defrust first_length(names) do
      Enum.find_value(names, fn name -> if(name.is_empty(), do: nil, else: some(name.len())) end)
    end

    @spec capped([integer()]) :: integer()
    defrust capped(values) do
      Enum.reduce_while(values, 0, fn value, sum ->
        if sum + value > 10, do: {:halt, sum}, else: {:cont, sum + value}
      end)
    end

    @spec sorted([String.t()]) :: [String.t()]
    defrust(sorted(names), do: Enum.sort_by(names, fn name -> name.len() end, :desc))

    @spec longest([String.t()]) :: R.option(String.t())
    defrust(longest(names), do: Enum.max_by(names, fn name -> name.len() end, fn -> nil end))

    @spec smallest([integer()]) :: integer()
    defrust(smallest(values), do: Enum.min(values, fn -> 0 end))

    @spec distinct([String.t()]) :: [String.t()]
    defrust(distinct(names), do: Enum.uniq(names))

    @spec split([integer()]) :: {[integer()], [integer()]}
    defrust(split(values), do: Enum.split_with(values, fn value -> value > 0 end))

    @spec second([String.t()]) :: R.option(String.t())
    defrust(second(names), do: Enum.at(names, 1))

    @spec leading([integer()]) :: [integer()]
    defrust(leading(values), do: Enum.take_while(values, fn value -> value > 0 end))

    @spec sums([integer()], [integer()]) :: [integer()]
    defrust(sums(left, right), do: Enum.zip_with(left, right, fn x, y -> x + y end))

    @spec pairs([integer()]) :: [[integer()]]
    defrust(pairs(values), do: Enum.chunk_every(values, 2))

    @spec joined([String.t()]) :: String.t()
    defrust(joined(names), do: Enum.join(names, ", "))

    @spec described([integer()]) :: String.t()
    defrust(described(values), do: Enum.map_join(values, "-", fn value -> value.to_string() end))

    @spec named([String.t()]) :: MapSet.t(String.t())
    defrust(named(names), do: Enum.into(names, MapSet.new()))
  end

  defmodule Pipelines do
    @moduledoc "`Enum` pipelines, which run as one Rust iterator chain."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec first_long([String.t()]) :: R.option(R.usize())
    defrust first_long(names) do
      names |> Enum.map(fn name -> name.len() end) |> Enum.find(fn length -> length > 3 end)
    end

    @spec positive_product([integer()]) :: integer()
    defrust positive_product(values) do
      values
      |> Enum.filter(fn value -> value > 0 end)
      |> Enum.reduce(1, fn value, product -> value * product end)
    end

    @spec doubled_sum([integer()]) :: integer()
    defrust(doubled_sum(values), do: Enum.sum(Enum.map(values, fn value -> value * 2 end)))

    @spec nth_set(R.option(String.t()), R.option(String.t()), R.usize()) :: R.option(R.usize())
    defrust nth_set(name, text, index) do
      set = [name.is_some(), text.is_some()]

      case set
           |> Enum.with_index()
           |> Enum.filter(fn {set, _field} -> set end)
           |> Enum.at(index) do
        {:some, {_set, field}} -> some(field)
        :none -> nil
      end
    end

    @spec set_count(R.option(String.t()), R.option(String.t())) :: R.usize()
    defrust set_count(name, text) do
      set = [name.is_some(), text.is_some()]
      Enum.count(set, fn set -> set end)
    end

    @spec labelled(R.ref(R.option(String.t())), R.usize()) :: R.option({String.t(), R.usize()})
    defrust labelled(name, field) do
      case field do
        0 -> name.as_ref().map(fn value -> {value.clone(), field} end)
        _ -> nil
      end
    end
  end

  test "a question borrows the list it asks about" do
    assert rust_source!(Lists, :any_long) =~ "names.iter().any(|name| name.len() > 3)"
  end

  test "the list's last use takes it" do
    assert rust_source!(Lists, :lengths) =~ "names.into_iter().map(|name| name.len())"
  end

  test "a list a later value was built from is borrowed" do
    assert rust_source!(Lists, :padded) =~ ~r/names\s*\.iter\(\)\s*\.map\(/
  end

  test "items kept from a list still in use are copies" do
    assert rust_source!(Lists, :kept) =~
             ~r/names\s*\.iter\(\)\s*\.filter\(\|name\| name\.len\(\) > 3\)\s*\.cloned\(\)/
  end

  test "a list reached through a reference is borrowed" do
    assert rust_source!(Lists, :has_long) =~ ~r/roster\s*\.names\s*\.iter\(\)\s*\.any\(/
    assert rust_source!(Lists, :long_names) =~ ~r/roster\s*\.names\s*\.iter\(\)\s*\.cloned\(\)/
  end

  test "a closure borrows a new value for an argument taken by reference" do
    assert rust_source!(Lists, :checked) =~ "unseen(&name, &HashSet::new())"
  end

  test "cloning each item of a list of references is cloned()" do
    assert rust_source!(Lists, :copies) =~ "names.into_iter().cloned().collect"
  end

  test "a loop over a slice reads each item by reference" do
    assert rust_source!(Lists, :greet_all) =~ "greet(name);"
  end

  test "a generator over one value matches it beside the item" do
    source = rust_source!(Lists, :by_length)

    assert source =~ ".map(|name| (nonzero(name), name))"
    refute source =~ "vec!["
  end

  test "group_by keeps each group's items in order" do
    assert rust_source!(Queries, :by_length) =~
             "rustq_groups.entry(rustq_item.len()).or_default().push(rustq_item);"
  end

  test "with_index pairs items with usize indexes, and a generator enumerates without collecting" do
    assert rust_source!(Queries, :indexed) =~ ".enumerate()"
    assert rust_source!(Queries, :positions) =~ "names.iter().enumerate().map(|(index, name)|"
  end

  test "find_index, find_value, and reduce_while stop at the first answer" do
    assert rust_source!(Queries, :first_long) =~ "names.iter().position(|name| name.len() > 3)"
    assert rust_source!(Queries, :first_length) =~ "names.iter().find_map("
    assert rust_source!(Queries, :capped) =~ ".try_fold("
    assert rust_source!(Queries, :capped) =~ ".unwrap_or_else(|rustq_halted| rustq_halted)"
  end

  test "sort_by and max_by sort by key, first greatest first, and min is min" do
    assert rust_source!(Queries, :sorted) =~
             "sort_by_key(|rustq_item| std::cmp::Reverse(rustq_item.len()))"

    assert rust_source!(Queries, :longest) =~
             ".min_by_key(|rustq_item| std::cmp::Reverse(rustq_item.len()))"

    assert rust_source!(Queries, :smallest) =~ "values.into_iter().min().unwrap_or(0)"
  end

  test "uniq, split_with, at, take_while, zip_with, chunk_every, join, and into" do
    assert rust_source!(Queries, :distinct) =~ "rustq_seen.insert(rustq_item.clone())"
    assert rust_source!(Queries, :split) =~ ".partition::<Vec<i64>, _>(|&value| value > 0)"
    assert rust_source!(Queries, :second) =~ "names.get(1).cloned()"
    assert rust_source!(Queries, :leading) =~ ".take_while(|&value| value > 0)"
    assert rust_source!(Queries, :sums) =~ "left.into_iter().zip(right)"
    assert rust_source!(Queries, :pairs) =~ "values.chunks(2).map(|chunk| chunk.to_vec())"
    assert rust_source!(Queries, :joined) =~ ~s|names.join(", ")|
    assert rust_source!(Queries, :described) =~ ~s|.collect::<Vec<String>>().join("-")|
    assert rust_source!(Queries, :named) =~ "names.into_iter().collect()"
  end

  test "a pipeline of Enum stages collects no list between them" do
    assert rust_source!(Pipelines, :first_long) =~
             "names.into_iter().map(|name| name.len()).find(|&length| length > 3)"

    assert rust_source!(Pipelines, :positive_product) =~
             ~r/values\s*\.into_iter\(\)\s*\.filter\(\|&value\| value > 0\)\s*\.fold\(/

    assert rust_source!(Pipelines, :doubled_sum) =~
             "values.into_iter().map(|value| value * 2).sum()"
  end

  test "an item at an index of a stage is the iterator's nth, kept by a pattern on its copy" do
    assert rust_source!(Pipelines, :nth_set) =~
             ~r/\.filter\(\|&\(set, _field\)\| set\)\s*\.nth\(index\)/
  end

  test "a count where a usize is expected stays a usize" do
    assert rust_source!(Pipelines, :set_count) =~ ~r/\.filter\(\|&set\| set\)\s*\.count\(\)\n/
  end

  test "an option mapped from a reference's as_ref is an option already" do
    assert rust_source!(Pipelines, :labelled) =~
             "0 => name.as_ref().map(|value| (value.clone(), field)),"
  end
end
