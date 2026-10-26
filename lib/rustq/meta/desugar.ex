defmodule RustQ.Meta.Desugar do
  @moduledoc """
  Rewrites standard-library calls that are other Rusty-Elixir into that Rusty-Elixir, before
  `RustQ.Meta.Ownership` and lowering see a body, so lowering keeps to forms Rust has:

    * `Map.new/1,2`, `MapSet.new/1,2`, and `Enum.into/2,3` into an empty collection are a
      comprehension collecting into it;
    * `Enum.group_by/2,3` is a map filled by a loop, and `Enum.uniq/1` and `Enum.uniq_by/2`
      keep the items a set has not seen;
    * a generator over `Enum.with_index(list)` enumerates the list in place;
    * `left ++ right` is `Enum.concat(left, right)`.

  Where a rewrite needs what only lowering knows, it leaves an internal form for lowering to
  resolve: `__rustq_items__(list)` iterates a list as its ownership allows, and
  `__rustq_owned__(item, list)` is an item of `list`, copied where that costs nothing and
  cloned otherwise.
  """

  @doc "Rewrites `body`'s standard-library calls that are other Rusty-Elixir."
  @spec desugar(Macro.t()) :: Macro.t()
  def desugar(body), do: Macro.prewalk(body, &rewrite/1)

  @doc """
  A one-argument function applied to `value`, inlined: `fn name -> name.len() end` applied to
  `item` is `item.len()`, and `&key/1` applied to it is `key(item)`.
  """
  @spec apply_function(Macro.t(), Macro.t()) :: Macro.t()
  def apply_function({:fn, _, [{:->, _, [[{name, _, ast_context}], body]}]}, value)
      when is_atom(name) and is_atom(ast_context) do
    Macro.prewalk(body, fn
      {^name, _, ^ast_context} -> value
      node -> node
    end)
  end

  def apply_function({:fn, _, [{:->, _, [[pattern], body]}]}, value),
    do: quote(do: case(unquote(value), do: (unquote(pattern) -> unquote(body))))

  def apply_function({:&, _, [{:/, _, [{{:., _, _} = remote, _, _}, 1]}]}, value),
    do: {remote, [], [value]}

  def apply_function({:&, _, [{:/, _, [{name, _, _}, 1]}]}, value) when is_atom(name),
    do: {name, [], [value]}

  def apply_function(other, _value) do
    RustQ.Diagnostic.lower(
      :unsupported_enum_function,
      other,
      "unsupported function argument in defrust",
      suggestion: "Use a one-argument anonymous function or a named one-argument capture."
    )
  end

  # Names a rewrite introduces, which shadow nothing a body writes.
  defp fresh(name), do: Macro.var(:"rustq_#{name}", __MODULE__)

  defp rewrite({{:., _, [{:__aliases__, _, [:Map]}, :new]}, _, [enumerable | transform]}),
    do: comprehension(enumerable, transform, quote(do: HashMap.new()))

  defp rewrite({{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, [enumerable | transform]}),
    do: comprehension(enumerable, transform, quote(do: HashSet.new()))

  defp rewrite(
         {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, [enumerable, collectable | transform]} =
           call
       ) do
    case empty_collection(collectable) do
      nil -> call
      into -> comprehension(enumerable, transform, into)
    end
  end

  # Groups keep their items in order, as Elixir's do.
  defp rewrite({{:., _, [{:__aliases__, _, [:Enum]}, :group_by]}, _, [enumerable, key | value]}) do
    item = fresh(:item)
    groups = fresh(:groups)
    value = if value == [], do: item, else: apply_function(hd(value), item)

    quote do
      unquote(groups) = HashMap.new()

      for unquote(item) <- unquote(enumerable) do
        unquote(groups).entry(unquote(apply_function(key, item))).or_default().push(
          unquote(value)
        )
      end

      unquote(groups)
    end
  end

  # Keeps each item whose key is new, in order, as Elixir does.
  defp rewrite({{:., _, [{:__aliases__, _, [:Enum]}, function]}, _, [enumerable | key]} = call)
       when function in [:uniq, :uniq_by] do
    if length(key) == if(function == :uniq, do: 0, else: 1) do
      item = fresh(:item)
      seen = fresh(:seen)

      seen_key =
        case key do
          [] -> quote(do: __rustq_owned__(unquote(item), unquote(enumerable)))
          [key] -> apply_function(key, item)
        end

      quote do
        unquote(seen) = HashSet.new()

        Enum.filter(unquote(enumerable), fn unquote(item) ->
          unquote(seen).insert(unquote(seen_key))
        end)
      end
    else
      call
    end
  end

  defp rewrite({:++, _, [left, right]}), do: quote(do: Enum.concat(unquote(left), unquote(right)))

  defp rewrite({:for, meta, args}), do: {:for, meta, Enum.map(args, &indexed_generator/1)}
  defp rewrite(ast), do: ast

  # `{item, index} <- Enum.with_index(list)` enumerates the list, binding `{index, item}`,
  # rather than collecting the pairs first.
  defp indexed_generator(
         {:<-, meta, [pattern, {{:., _, [{:__aliases__, _, [:Enum]}, :with_index]}, _, [list]}]}
       ) do
    enumerated = quote(do: __rustq_items__(unquote(list)) |> enumerate())

    case pattern do
      {item, index} ->
        {:<-, meta, [{index, item}, enumerated]}

      pattern ->
        {:<-, meta,
         [pattern, quote(do: unquote(enumerated) |> map(fn {index, item} -> {item, index} end))]}
    end
  end

  defp indexed_generator(qualifier), do: qualifier

  defp comprehension(enumerable, [], into),
    do: quote(do: for(item <- unquote(enumerable), into: unquote(into), do: item))

  defp comprehension(enumerable, [{:fn, _, [{:->, _, [[pattern], body]}]}], into),
    do:
      quote(
        do: for(unquote(pattern) <- unquote(enumerable), into: unquote(into), do: unquote(body))
      )

  defp comprehension(enumerable, [transform], into) do
    item = fresh(:item)

    quote do
      for unquote(item) <- unquote(enumerable),
          into: unquote(into),
          do: unquote(apply_function(transform, item))
    end
  end

  # The collection an empty collectable names, or nil for one with items.
  defp empty_collection({:%{}, _, []}), do: quote(do: HashMap.new())
  defp empty_collection([]), do: quote(do: Vec.new())

  defp empty_collection({{:., _, [{:__aliases__, _, [module]}, :new]}, _, []} = constructor)
       when module in [:Map, :MapSet, :HashMap, :HashSet, :BTreeMap, :BTreeSet],
       do: constructor

  defp empty_collection(_collectable), do: nil
end
