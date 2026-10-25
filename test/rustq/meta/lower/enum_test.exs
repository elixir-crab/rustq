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

    @spec nonzero(R.ref(String.t())) :: R.option(R.usize())
    defrust(nonzero(name), do: if(name.is_empty(), do: nil, else: some(name.len())))
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
    assert rust_source!(Lists, :kept) =~ ~r/names\s*\.iter\(\)\s*\.cloned\(\)\s*\.filter_map\(/
  end

  test "a closure borrows a new value for an argument taken by reference" do
    assert rust_source!(Lists, :checked) =~ "unseen(&name, &HashSet::new())"
  end

  test "a generator over one value matches it beside the item" do
    source = rust_source!(Lists, :by_length)

    assert source =~ ".map(|name| (name, nonzero(name)))"
    refute source =~ "vec!["
  end
end
