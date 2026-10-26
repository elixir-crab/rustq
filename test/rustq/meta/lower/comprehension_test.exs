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
  end

  test "a list of tuples still in use is iterated by reference, copying copy elements" do
    source = rust_source!(Entries, :missing)

    assert source =~ ".iter()"
    assert source =~ "(*element1, element2)"
    refute source =~ ".cloned()"
  end
end
