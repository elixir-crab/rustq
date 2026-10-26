defmodule RustQ.Meta.Lower.Kernel do
  @moduledoc """
  Lowers `Kernel` operators and functions such as `elem/2`, `put_elem/3`, `abs/1`, and
  `is_nil/1` for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  use RustQ.Meta.Lower.Stdlib.Lowering

  alias RustQ.Diagnostic
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Type
  alias RustQ.Spec

  @binary_ops %{
    ==: :eq,
    !=: :ne,
    <: :lt,
    <=: :lte,
    >: :gt,
    >=: :gte,
    +: :add,
    -: :sub,
    *: :mul,
    /: :div,
    div: :div,
    rem: :rem,
    and: :and,
    or: :or
  }

  @comparison_functions [:==, :!=, :<, :<=, :>, :>=, :and, :or, :not, :is_nil]

  @impl true
  def lower(%Call{function: function} = call, %Context{} = context)
      when function in [:.., :..//, :in],
      do: RustQ.Meta.Lower.Range.lower(call, context)

  def lower(%Call{function: :/, args: [left, right]} = call, %Context{} = context) do
    if integer_type?(type_of(left, context)) or integer_type?(type_of(right, context)) do
      unsupported_semantics!(
        call,
        "Kernel.//2 with integer operands requires an explicit floating-point conversion"
      )
    else
      {:ok, A.binary(operand(left, context), :div, operand(right, context))}
    end
  end

  # Comparing a collection or string with an empty one asks whether it is empty.
  def lower(%Call{function: function, args: [collection, empty]}, %Context{} = context)
      when function in [:==, :!=] and empty in [[], ""],
      do: {:ok, emptiness(function, collection, context)}

  def lower(%Call{function: function, args: [collection, {:%{}, _, []}]}, %Context{} = context)
      when function in [:==, :!=],
      do: {:ok, emptiness(function, collection, context)}

  # Comparing an option with `nil` asks whether it holds a value, which needs no equality on
  # what it holds.
  def lower(%Call{function: function, args: [option, nil]}, %Context{} = context)
      when function in [:==, :!=] do
    method = if function == :==, do: :is_none, else: :is_some
    {:ok, A.method(lowered(option, context), method)}
  end

  # Comparing two options or results compares the wrappers; neither side propagates.
  def lower(%Call{function: function, args: [left, right]}, %Context{} = context)
      when function in [:==, :!=] do
    if wrapper_comparison?(left, right, context),
      do:
        {:ok,
         A.binary(
           lowered(left, context),
           Map.fetch!(@binary_ops, function),
           lowered(right, context)
         )},
      else: {:ok, compared(function, left, right, context)}
  end

  def lower(%Call{function: function, args: [left, right]}, %Context{} = context)
      when function in @comparison_functions and is_map_key(@binary_ops, function),
      do: {:ok, compared(function, left, right, context)}

  def lower(%Call{function: function, args: [left, right]}, %Context{} = context)
      when is_map_key(@binary_ops, function) do
    {:ok,
     A.binary(operand(left, context), Map.fetch!(@binary_ops, function), operand(right, context))}
  end

  def lower(%Call{function: :-, args: [expression]}, %Context{} = context),
    do: {:ok, A.neg(lowered(expression, context))}

  def lower(%Call{function: :+, args: [expression]}, %Context{} = context),
    do: {:ok, lowered(expression, context)}

  def lower(%Call{function: :not, args: [expression]}, %Context{} = context),
    do: {:ok, A.not_(lowered(expression, context))}

  def lower(%Call{function: :abs, args: [expression]}, %Context{} = context),
    do: {:ok, A.method(lowered(expression, context), :abs)}

  def lower(%Call{function: function, args: [left, right]} = call, %Context{} = context)
      when function in [:min, :max] do
    if integer_type?(type_of(left, context)) and integer_type?(type_of(right, context)) do
      {:ok, A.method(lowered(left, context), function, [lowered(right, context)])}
    else
      unsupported_semantics!(
        call,
        "Kernel.#{function}/2 currently requires statically typed integers"
      )
    end
  end

  def lower(%Call{function: function, args: [value]}, %Context{} = context)
      when function in [:byte_size, :length],
      do: {:ok, value |> lowered(context) |> A.method(:len) |> integer_count(context)}

  def lower(%Call{function: :map_size, args: [map]} = call, %Context{} = context) do
    type = shape_type(type_of(map, context))

    cond do
      match?({:map, _key, _value}, Collection.keyed(type)) ->
        {:ok, map |> lowered(context) |> A.method(:len) |> integer_count(context)}

      is_list(struct_fields(type)) ->
        evaluated_constant(map, length(struct_fields(type)), context)

      true ->
        unsupported_semantics!(call, "map_size/1 requires a statically typed map or struct")
    end
  end

  def lower(%Call{function: :elem, args: [tuple, index]}, %Context{} = context)
      when is_integer(index) and index >= 0,
      do: {:ok, A.field(lowered(tuple, context), index)}

  def lower(%Call{function: :put_elem, args: [tuple, index, value]} = call, %Context{} = context)
      when is_integer(index) and index >= 0 do
    case tuple_elements(type_of(tuple, context)) do
      elements when index < length(elements) ->
        tuple_name = :rustq_tuple_value
        tuple_var = A.var(tuple_name)

        values =
          elements
          |> Elixir.Enum.with_index()
          |> Elixir.Enum.map(fn
            {type, ^index} -> lowered(value, type, context)
            {_type, field} -> A.field(tuple_var, field)
          end)

        {:ok,
         A.block_expr([
           %AST.Let{pattern: %AST.PatVar{name: tuple_name}, expr: lowered(tuple, context)},
           A.return_stmt(A.tuple(values))
         ])}

      _unknown ->
        unsupported_semantics!(
          call,
          "put_elem/3 requires a statically typed tuple and literal index"
        )
    end
  end

  def lower(%Call{function: :tuple_size, args: [tuple]} = call, %Context{} = context) do
    case tuple_elements(shape_type(type_of(tuple, context))) do
      elements when is_list(elements) ->
        evaluated_constant(tuple, length(elements), context)

      _unknown ->
        unsupported_semantics!(call, "tuple_size/1 requires a statically typed tuple")
    end
  end

  def lower(%Call{function: :is_nil, args: [value]}, %Context{} = context),
    do: {:ok, A.method(lowered(value, context), :is_none)}

  def lower(%Call{}, %Context{}), do: :unsupported

  @impl true
  def synth(%Call{function: function} = call, %TypeContext{} = context)
      when function in [:.., :..//, :in],
      do: RustQ.Meta.Lower.Range.synth(call, context)

  def synth(%Call{function: function}, %TypeContext{}) when function in @comparison_functions,
    do: {:ok, Spec.type(quote(do: boolean()))}

  # Arithmetic on an option or result works on the value its operand propagates.
  def synth(%Call{function: function, args: [left | _rest]}, %TypeContext{} = context)
      when function in [:+, :-, :*, :/, :div, :rem, :abs, :min, :max],
      do: left |> type_of(context) |> propagated_value() |> type_result()

  def synth(%Call{function: function}, %TypeContext{})
      when function in [:byte_size, :length, :map_size, :tuple_size],
      do: {:ok, Spec.type(quote(do: integer()))}

  def synth(%Call{function: :elem, args: [tuple, index]}, %TypeContext{} = context)
      when is_integer(index) and index >= 0 do
    case tuple_elements(type_of(tuple, context)) do
      elements when index < length(elements) -> type_result(Elixir.Enum.at(elements, index))
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :put_elem, args: [tuple, _index, _value]}, %TypeContext{} = context),
    do: type_result(type_of(tuple, context))

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp tuple_elements(%Type{kind: :tuple, meta: %{elements: elements}}), do: elements
  defp tuple_elements(_type), do: nil

  defp struct_fields(%Type{kind: :alias, meta: %{target: %Type{} = target}}),
    do: struct_fields(target)

  defp struct_fields(%Type{kind: :struct, meta: %{fields: fields}}), do: fields
  defp struct_fields(%Type{} = type), do: type |> Type.ref_inner() |> struct_fields()
  defp struct_fields(_type), do: nil

  defp integer_type?(%Type{} = type), do: Type.category(type) == :integer
  defp integer_type?(_type), do: false

  defp type_result(%Type{} = type), do: {:ok, type}
  defp type_result(_type), do: :unsupported

  @spec unsupported_semantics!(Call.t(), String.t()) :: no_return()
  defp unsupported_semantics!(%Call{source: source}, message) do
    Diagnostic.lower(
      :unsupported_stdlib_semantics,
      source,
      message,
      suggestion: "Use an explicit Rust adapter when Elixir and Rust semantics differ."
    )
  end

  # Elixir's integer, as a count is, compares in the Rust integer type of the other side.
  # A boolean operator takes booleans, and a comparison values of one type: a borrowed copy
  # operand is read where the other is not borrowed or the operator is boolean, and an atom
  # or integer literal takes the other operand's type.
  defp compared(function, left, right, context) do
    {left_type, right_type} = {type_of(left, context), type_of(right, context)}
    logical? = function in [:and, :or]

    A.binary(
      compared_operand(left, left_type, right_type, logical?, context),
      Map.fetch!(@binary_ops, function),
      compared_operand(right, right_type, left_type, logical?, context)
    )
  end

  defp compared_operand(operand, %Type{kind: :i64}, %Type{kind: kind} = other, _logical?, context)
       when kind in [:u8, :u16, :u32, :u64, :usize, :i8, :i16, :i32, :isize],
       do: lowered(operand, other, context)

  defp compared_operand(operand, _type, %Type{} = other, false, context)
       when is_atom(operand) and operand not in [nil, true, false],
       do: lowered(operand, other, context)

  defp compared_operand(operand, %Type{kind: :ref} = type, other, logical?, context) do
    if Collection.copy?(Type.ref_inner(type)) and (logical? or not borrowed?(other)),
      do: A.deref(lowered(operand, context)),
      else: operand(operand, context)
  end

  defp compared_operand(operand, _type, _other, _logical?, context), do: operand(operand, context)

  defp borrowed?(%Type{kind: kind}), do: kind in [:ref, :mut_ref]
  defp borrowed?(_type), do: false

  defp emptiness(function, collection, context) do
    is_empty = collection |> lowered(context) |> A.method(:is_empty)
    if function == :==, do: is_empty, else: A.not_(is_empty)
  end

  defp wrapper_comparison?(left, right, %Context{} = context) do
    wrapper_literal?(left) or wrapper_literal?(right) or
      (wrapper_kind(type_of(left, context)) != nil and
         wrapper_kind(type_of(left, context)) == wrapper_kind(type_of(right, context)))
  end

  defp wrapper_literal?({:some, _, [_value]}), do: true
  defp wrapper_literal?({:ok, _, [_value]}), do: true
  defp wrapper_literal?({:err, _, [_value]}), do: true
  defp wrapper_literal?(value) when value in [nil, :none], do: true
  defp wrapper_literal?({tag, _value}) when tag in [:some, :ok, :error], do: true
  defp wrapper_literal?(_expression), do: false

  defp wrapper_kind(%Type{kind: :option}), do: :option
  defp wrapper_kind(%Type{kind: kind}) when kind in [:result, :nif_result], do: :result
  defp wrapper_kind(_type), do: nil

  # Arithmetic on a borrowed number gives a number, as Rust's operators on references do.
  defp propagated_value(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: Type.ref_inner(type) || type

  defp propagated_value(%Type{} = type) do
    if Type.propagates?(type), do: Type.inner(type) || type, else: type
  end

  defp propagated_value(type), do: type
end
