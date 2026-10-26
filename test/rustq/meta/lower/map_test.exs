defmodule RustQ.Meta.Lower.MapTest do
  use RustQ.Test, async: true

  defmodule Scores do
    @moduledoc "`Map` functions on a `HashMap`."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec score(R.ref(%{String.t() => integer()}), String.t()) :: integer()
    defrust(score(scores, name), do: Map.get(scores, name, 0))

    @spec found(R.ref(%{String.t() => integer()}), R.ref(String.t())) :: R.option(integer())
    defrust(found(scores, name), do: Map.get(scores, name))

    @spec known?(R.ref(%{String.t() => integer()}), R.ref(String.t())) :: R.bool()
    defrust(known?(scores, name), do: Map.has_key?(scores, name))

    @spec bump(%{String.t() => integer()}, String.t()) :: %{String.t() => integer()}
    defrust(bump(scores, name), do: Map.update(scores, name, 1, fn count -> count + 1 end))

    @spec added(%{String.t() => integer()}, String.t()) :: %{String.t() => integer()}
    defrust(added(scores, name), do: Map.put(scores, name, 0))

    @spec kept(%{String.t() => integer()}, String.t()) ::
            {%{String.t() => integer()}, %{String.t() => integer()}}
    defrust kept(scores, name) do
      fewer = Map.delete(scores, ref(name))
      {fewer, scores}
    end

    @spec combined(%{String.t() => integer()}, %{String.t() => integer()}) ::
            %{String.t() => integer()}
    defrust(combined(scores, more), do: Map.merge(scores, more))

    @spec names(R.ref(%{String.t() => integer()})) :: [String.t()]
    defrust(names(scores), do: Map.keys(scores))

    @spec beside(%{String.t() => integer()}, String.t()) ::
            {%{String.t() => integer()}, %{String.t() => integer()}}
    defrust(beside(scores, name), do: {Map.put(scores, name, 1), scores})

    @spec tallied(%{String.t() => integer()}, String.t()) :: %{String.t() => integer()}
    defrust tallied(scores, name) do
      scores = Map.put(scores, name, 1)
      scores
    end

    @spec lengths([String.t()]) :: %{String.t() => R.usize()}
    defrust(lengths(names), do: Map.new(names, fn name -> {name.clone(), name.len()} end))
  end

  test "reads copy values out" do
    assert rust_source!(Scores, :score) =~ "scores.get(&name).copied().unwrap_or(0)"
    assert rust_source!(Scores, :found) =~ "scores.get(name).copied()"
    assert rust_source!(Scores, :known?) =~ "scores.contains_key(name)"
  end

  test "update/4 gives a present value to the function and stores the default otherwise" do
    source = rust_source!(Scores, :bump)

    assert source =~ ".remove(&rustq_key)"
    assert source =~ ".map(|count| count + 1)"
    assert source =~ ".unwrap_or(1)"
  end

  test "an update takes the map at its last use and copies it otherwise" do
    assert rust_source!(Scores, :added) =~ "let mut rustq_updated = scores;"
    assert rust_source!(Scores, :kept) =~ "let mut rustq_updated = scores.clone();"
  end

  test "an update copies a map the same expression uses after it" do
    assert rust_source!(Scores, :beside) =~ "let mut rustq_updated = scores.clone();"
  end

  test "rebinding a map to its update changes it in place" do
    source = rust_source!(Scores, :tallied)

    assert source =~ "scores.insert(name, 1);"
    refute source =~ "rustq_updated"
  end

  test "merge, keys, and new collect as Elixir's do" do
    assert rust_source!(Scores, :combined) =~ "rustq_updated.extend(more);"
    assert rust_source!(Scores, :names) =~ "scores.keys().cloned().collect::<Vec<String>>()"

    assert rust_source!(Scores, :lengths) =~
             "names.into_iter().map(|name| (name.clone(), name.len())).collect()"
  end
end
