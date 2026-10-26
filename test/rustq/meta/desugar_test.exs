defmodule RustQ.Meta.DesugarTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.Desugar

  defp desugared(ast), do: ast |> Desugar.desugar() |> Macro.to_string()

  test "Map.new, MapSet.new, and Enum.into an empty collection are comprehensions" do
    assert desugared(quote(do: Map.new(pairs))) ==
             "for item <- pairs, into: HashMap.new(), do: item"

    assert desugared(quote(do: MapSet.new(names, fn name -> name.len() end))) ==
             "for name <- names, into: HashSet.new(), do: name.len()"

    assert desugared(quote(do: Enum.into(names, %{}, &pair/1))) ==
             "for rustq_item <- names, into: HashMap.new(), do: pair(rustq_item)"

    assert desugared(quote(do: Enum.into(names, scores))) == "Enum.into(names, scores)"
  end

  test "group_by fills a map in a loop, keeping each group's order" do
    assert desugared(quote(do: Enum.group_by(names, fn name -> name.len() end))) =~
             "rustq_groups.entry(rustq_item.len()).or_default().push(rustq_item)"
  end

  test "uniq keeps the items a set has not seen, copied or cloned as lowering decides" do
    assert desugared(quote(do: Enum.uniq(names))) =~
             "rustq_seen.insert(__rustq_owned__(rustq_item, names))"

    assert desugared(quote(do: Enum.uniq_by(names, &key/1))) =~
             "rustq_seen.insert(key(rustq_item))"
  end

  test "a generator over Enum.with_index enumerates the list in place" do
    assert desugared(quote(do: for({name, index} <- Enum.with_index(names), do: f(name, index)))) ==
             "for {index, name} <- __rustq_items__(names) |> enumerate() do\n  f(name, index)\nend"
  end
end
