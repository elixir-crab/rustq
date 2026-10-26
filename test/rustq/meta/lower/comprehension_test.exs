defmodule RustQ.Meta.Lower.ComprehensionTest do
  use RustQ.Test, async: true

  defmodule Entries do
    @moduledoc "Comprehensions over a list of tuples."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec missing([{R.u32(), R.option(String.t())}]) ::
            {[R.u32()], [{R.u32(), R.option(String.t())}]}
    defrust missing(entries) do
      ids = for {id, nil} <- entries, do: id
      {ids, entries}
    end

    @type group :: %{required(:names) => [String.t()]}

    @spec named(R.slice(group())) :: [String.t()]
    defrust(named(groups),
      do: for(group <- groups, name <- group.names, name != "", do: name.clone())
    )

    @spec totals(R.slice(R.u32())) :: %{R.u32() => R.u32()}
    defrust totals(values) do
      for value <- values, reduce: %{} do
        totals -> Map.update(totals, value, 1, fn count -> count + 1 end)
      end
    end
  end

  test "a list of tuples still in use is iterated by reference, copying copy elements" do
    source = rust_source!(Entries, :missing)

    assert source =~ ".iter()"
    assert source =~ "(*element1, element2)"
    refute source =~ ".cloned()"
  end

  test "a list an item of an earlier generator holds is iterated by reference" do
    source = rust_source!(Entries, :named)

    assert source =~ ~r/\.names\s+\.iter\(\)/
    refute source =~ ".into_iter()"
  end

  test "a reduction with one clause binding the accumulator names it, typed" do
    source = rust_source!(Entries, :totals)

    assert source =~ "let mut totals: HashMap<u32, u32> = HashMap::new();"
    assert source =~ "totals = {"
    refute source =~ "__rustq_reduce"
  end
end
