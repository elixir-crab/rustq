defmodule RustQ.Meta.Lower.MapSet do
  @moduledoc """
  Lowers `MapSet` functions on a `HashSet` or `BTreeSet` for `RustQ.Meta.Lower.Stdlib`, and
  types such calls: `new/0` (`new/1,2` are comprehensions; see `RustQ.Meta.Desugar`), `put`, `delete`, `member?`, `union`, `difference`, `intersection`,
  `subset?`, `disjoint?`, `size`, and `to_list`. An update takes the set only at its last use;
  see `RustQ.Meta.Lower.Collection`.
  """

  use RustQ.Meta.Lower.Stdlib.Lowering

  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Type

  @impl true
  # A new set where a reference to one is expected is borrowed.
  def lower(%Call{function: :new, args: []}, %Context{expected: %Type{kind: :ref}}),
    do: {:ok, A.ref(A.path_call([:HashSet, :new]))}

  def lower(%Call{function: :new, args: []}, %Context{}),
    do: {:ok, A.path_call([:HashSet, :new])}

  def lower(%Call{args: [set | _]} = call, %Context{} = context) do
    case Collection.keyed_of(set, context) do
      {:set, item} -> lower_set(call, item, context)
      _other -> :unsupported
    end
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  defp lower_set(%Call{function: :put, args: [set, value]}, item, context) do
    {:ok,
     Collection.updated(
       set,
       fn set ->
         [A.stmt(A.method(set, :insert, [lowered(value, item, context)]))]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: :delete, args: [set, value]}, item, context) do
    {:ok,
     Collection.updated(
       set,
       fn set ->
         [A.stmt(A.method(set, :remove, [Collection.borrowed(value, item, context)]))]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: :member?, args: [set, value]}, item, context) do
    {:ok, A.method(lowered(set, context), :contains, [Collection.borrowed(value, item, context)])}
  end

  defp lower_set(%Call{function: :union, args: [set, other]}, _item, context) do
    {:ok,
     Collection.updated(
       set,
       fn set ->
         [A.stmt(A.method(set, :extend, [Collection.owned(other, context)]))]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: function, args: [set, other]}, _item, context)
       when function in [:difference, :intersection] do
    kept = A.method(lowered(other, context), :contains, [A.var(:rustq_item)])

    kept = if function == :difference, do: A.not_(kept), else: kept

    {:ok,
     Collection.updated(
       set,
       fn set ->
         [A.stmt(A.method(set, :retain, [A.closure([:rustq_item], kept)]))]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: function, args: [set, other]}, _item, context)
       when function in [:subset?, :disjoint?] do
    method = if function == :subset?, do: :is_subset, else: :is_disjoint

    {:ok, A.method(lowered(set, context), method, [A.ref(lowered(other, context))])}
  end

  defp lower_set(%Call{function: :size, args: [set]}, _item, context) do
    {:ok, set |> lowered(context) |> A.method(:len) |> integer_count(context)}
  end

  defp lower_set(%Call{function: :to_list, args: [set]}, item, context) do
    collected =
      set
      |> Collection.owned(context)
      |> A.method(:into_iter)
      |> A.method(:collect)

    {:ok, %{collected | generics: [Type.vec(item).ast]}}
  end

  defp lower_set(%Call{}, _item, _context), do: :unsupported

  @impl true
  def synth(%Call{function: :new}, %TypeContext{}), do: :unsupported

  def synth(%Call{function: function, args: [set | _]}, %TypeContext{} = context) do
    case {function, Collection.keyed(type_of(set, context))} do
      {_function, nil} ->
        :unsupported

      {function, _set} when function in [:member?, :subset?, :disjoint?] ->
        {:ok, RustQ.Spec.type(quote(do: boolean()))}

      {:size, _set} ->
        {:ok, RustQ.Spec.type(quote(do: integer()))}

      {:to_list, {:set, item}} ->
        {:ok, Type.vec(item)}

      {function, _set} when function in [:put, :delete, :union, :difference, :intersection] ->
        owned(type_of(set, context))

      _other ->
        :unsupported
    end
  end

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp owned(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: {:ok, Type.ref_inner(type)}

  defp owned(%Type{} = type), do: {:ok, type}
end
