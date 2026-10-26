defmodule RustQ.Meta.Lower.MapSetTest do
  use RustQ.Test, async: true

  defmodule Seen do
    @moduledoc "`MapSet` functions on a `HashSet`."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec seen(MapSet.t(String.t()), String.t()) :: MapSet.t(String.t())
    defrust(seen(set, name), do: MapSet.put(set, name))

    @spec known?(R.ref(MapSet.t(String.t())), R.ref(String.t())) :: R.bool()
    defrust(known?(set, name), do: MapSet.member?(set, name))

    @spec unseen(MapSet.t(String.t()), R.ref(MapSet.t(String.t()))) :: MapSet.t(String.t())
    defrust(unseen(set, other), do: MapSet.difference(set, other))

    @spec flagged() :: MapSet.t(R.u32())
    defrust(flagged(), do: MapSet.new([1, 2]))

    @spec count([String.t()]) :: integer()
    defrust count(names) do
      set = MapSet.new(names)
      MapSet.size(set)
    end
  end

  test "a set of listed items is built from an array of them" do
    assert rust_source!(Seen, :flagged) =~ "HashSet::from([1, 2])"
  end

  test "MapSet.t is a HashSet" do
    assert rust_source!(Seen, :seen) =~
             "fn seen(set: HashSet<String>, name: String) -> HashSet<String>"

    assert rust_source!(Seen, :seen) =~ "rustq_updated.insert(name);"
  end

  test "member? and difference read the other set" do
    assert rust_source!(Seen, :known?) =~ "set.contains(name)"

    assert rust_source!(Seen, :unseen) =~
             "rustq_updated.retain(|rustq_item| !other.contains(rustq_item));"
  end

  test "new collects a list it takes at its last use" do
    source = rust_source!(Seen, :count)

    assert source =~ "names.into_iter().collect::<HashSet<String>>()"
    assert source =~ "set.len() as i64"
  end
end
