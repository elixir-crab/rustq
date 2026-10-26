defmodule RustQ.Meta.Lower.RangeTest do
  use RustQ.Test, async: true

  defmodule Counts do
    @moduledoc "Ranges with dynamic bounds."

    use RustQ.Meta

    alias RustQ.Type, as: R

    @spec read() :: R.nif_result(R.u32())
    defrustp(read(), do: {:ok, 3})

    @spec doubled(R.u32()) :: [R.u32()]
    defrustp(doubled(count), do: for(value <- 1..count//1, do: value * 2))

    @spec counted(R.mut_ref(R.vec(R.u32()))) :: R.nif_result(R.unit())
    defrustp counted(values) do
      count = read()

      for value <- 1..count//1 do
        values.push(value)
      end

      :ok
    end
  end

  test "a range a method is called on is parenthesized" do
    assert rust_source!(Counts, :doubled) =~ "(1..=count).into_iter()"
  end

  test "a fallible bound propagates its error" do
    assert rust_source!(Counts, :counted) =~ "1..=count?"
  end
end
