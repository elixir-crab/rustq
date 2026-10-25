defmodule RustQ.Meta.OwnershipTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.Ownership

  # Whether each use of `name`, in order, is still in use after it; a pattern binding the name
  # is not a use.
  defp uses(body, name, vars \\ %{}) do
    {annotated, built_from} = Ownership.annotate(body)

    annotated
    |> Macro.prewalk([], fn
      {^name, meta, context} = node, uses when is_atom(context) ->
        if Keyword.has_key?(meta, :rustq_live_after),
          do: {node, [Ownership.in_use?(node, built_from, vars) | uses]},
          else: {node, uses}

      node, uses ->
        {node, uses}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  test "the last use in order is the last" do
    assert uses(quote(do: {f(list), g(list)}), :list) == [true, false]
  end

  test "branches are alternatives" do
    body = quote(do: if(flag, do: f(list), else: g(list)))
    assert uses(body, :list) == [false, false]
  end

  test "a use after the branches keeps the branches' uses from being last" do
    body =
      quote do
        if flag, do: f(list)
        g(list)
      end

    assert uses(body, :list) == [true, false]
  end

  test "a closure's captures stay in use throughout it, its own variables do not" do
    body = quote(do: Enum.map(items, fn item -> f(list, item) end))

    assert uses(body, :list) == [true]
    assert uses(body, :item) == [false]
    assert uses(quote(do: fn item -> {f(item), g(item)} end), :item) == [true, false]
  end

  test "a shadowing inner closure does not hide what the outer one captures" do
    body = quote(do: Enum.map(list, fn item -> f(item, first.map(fn first -> first end)) end))
    assert uses(body, :first) == [true, false]
  end

  test "rebinding ends the value it replaces" do
    body =
      quote do
        list = sort(list)
        list
      end

    assert uses(body, :list) == [false, false]
  end

  test "a comprehension's collection is evaluated once, what its body captures is not" do
    body = quote(do: for(item <- list, do: f(item, other)))

    assert uses(body, :list) == [false]
    assert uses(body, :other) == [true]
  end

  test "a value built from another keeps it in use while it may borrow from it" do
    body =
      quote do
        index = by_id(records)
        Enum.map(records, fn record -> lookup(index, record) end)
      end

    assert uses(body, :records) == [true, true]

    owned = RustQ.Spec.type(quote(do: %{integer() => integer()}))
    assert uses(body, :records, %{index: owned}) == [true, false]
  end

  test "annotating keeps the shape lowering reads, as a with's do before its else" do
    body =
      quote do
        with {:some, value} <- lookup(key) do
          use(value)
        else
          _ -> :ok
        end
      end

    {{:with, _meta, [_clause, options]}, _built_from} = Ownership.annotate(body)
    assert Keyword.keys(options) == [:do, :else]
  end
end
