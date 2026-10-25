defmodule RustQ.Meta.Lower.MapSet do
  @moduledoc """
  Lowers `MapSet` functions on a `HashSet` or `BTreeSet` for `RustQ.Meta.Lower.Stdlib`, and
  types such calls: `new`, `put`, `delete`, `member?`, `union`, `difference`, `intersection`,
  `subset?`, `disjoint?`, `size`, and `to_list`. An update takes the set only at its last use;
  see `RustQ.Meta.Lower.Collection`.
  """

  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Lower.Map, as: MapLowering
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :new, args: []}, %Context{}),
    do: {:ok, %AST.PathCall{path: %AST.Path{parts: [:HashSet, :new]}, args: []}}

  def lower(%Call{function: :new, args: [enumerable | transform]}, %Context{} = context) do
    {:ok,
     MapLowering.collect(
       MapLowering.comprehension(enumerable, transform, quote(do: HashSet.new())),
       context
     )}
  end

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
         [Collection.statement(set, :insert, [context.lower_expected.(value, item)])]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: :delete, args: [set, value]}, item, context) do
    {:ok,
     Collection.updated(
       set,
       fn set ->
         [Collection.statement(set, :remove, [Collection.borrowed(value, item, context)])]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: :member?, args: [set, value]}, item, context) do
    {:ok,
     Collection.call(context.lower.(set), :contains, [Collection.borrowed(value, item, context)])}
  end

  defp lower_set(%Call{function: :union, args: [set, other]}, _item, context) do
    {:ok,
     Collection.updated(
       set,
       fn set ->
         [Collection.statement(set, :extend, [Collection.owned(other, context)])]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: function, args: [set, other]}, _item, context)
       when function in [:difference, :intersection] do
    kept = %AST.MethodCall{
      receiver: context.lower.(other),
      method: :contains,
      args: [%AST.Var{name: :rustq_item}]
    }

    kept = if function == :difference, do: %AST.UnaryOp{op: :not, expr: kept}, else: kept

    {:ok,
     Collection.updated(
       set,
       fn set ->
         [Collection.statement(set, :retain, [%AST.Closure{args: [:rustq_item], body: kept}])]
       end,
       context
     )}
  end

  defp lower_set(%Call{function: function, args: [set, other]}, _item, context)
       when function in [:subset?, :disjoint?] do
    method = if function == :subset?, do: :is_subset, else: :is_disjoint

    {:ok, Collection.call(context.lower.(set), method, [%AST.Ref{expr: context.lower.(other)}])}
  end

  defp lower_set(%Call{function: :size, args: [set]}, _item, context) do
    {:ok,
     %AST.Cast{
       expr: Collection.call(context.lower.(set), :len),
       type: %AST.TypePath{parts: [:i64]}
     }}
  end

  defp lower_set(%Call{function: :to_list, args: [set]}, item, context) do
    collected =
      set
      |> Collection.owned(context)
      |> Collection.call(:into_iter)
      |> Collection.call(:collect)

    {:ok, %{collected | generics: [Type.vec(item).ast]}}
  end

  defp lower_set(%Call{}, _item, _context), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: :new, args: [enumerable]}, %TypeContext{} = context) do
    with %Type{} = type <- context.type_of.(enumerable),
         %Type{} = item <- Type.vec_inner(type) || Type.slice_inner(type) do
      {:ok, Collection.set(item)}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :new}, %TypeContext{}), do: :unsupported

  def synth(%Call{function: function, args: [set | _]}, %TypeContext{} = context) do
    case {function, Collection.keyed(context.type_of.(set))} do
      {_function, nil} ->
        :unsupported

      {function, _set} when function in [:member?, :subset?, :disjoint?] ->
        {:ok, RustQ.Spec.type(quote(do: boolean()))}

      {:size, _set} ->
        {:ok, RustQ.Spec.type(quote(do: integer()))}

      {:to_list, {:set, item}} ->
        {:ok, Type.vec(item)}

      {function, _set} when function in [:put, :delete, :union, :difference, :intersection] ->
        owned(context.type_of.(set))

      _other ->
        :unsupported
    end
  end

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp owned(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: {:ok, Type.ref_inner(type)}

  defp owned(%Type{} = type), do: {:ok, type}
end
