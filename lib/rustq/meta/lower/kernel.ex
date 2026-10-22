defmodule RustQ.Meta.Lower.Kernel do
  @moduledoc false

  import RustQ.Meta.Lower.Stdlib, only: [evaluated_constant: 3, shape_type: 1]

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
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

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :/, args: [left, right]} = call, %Context{} = context) do
    if integer_type?(context.type_of.(left)) or integer_type?(context.type_of.(right)) do
      unsupported_semantics!(
        call,
        "Kernel.//2 with integer operands requires an explicit floating-point conversion"
      )
    else
      {:ok,
       %AST.BinaryOp{
         left: context.lower_binary_operand.(left),
         op: :div,
         right: context.lower_binary_operand.(right)
       }}
    end
  end

  # Comparing two options or results compares the wrappers; neither side propagates.
  def lower(%Call{function: function, args: [left, right]}, %Context{} = context)
      when function in [:==, :!=] do
    lower_operand =
      if wrapper_comparison?(left, right, context),
        do: context.lower,
        else: context.lower_binary_operand

    {:ok,
     %AST.BinaryOp{
       left: lower_operand.(left),
       op: Map.fetch!(@binary_ops, function),
       right: lower_operand.(right)
     }}
  end

  def lower(%Call{function: function, args: [left, right]}, %Context{} = context)
      when is_map_key(@binary_ops, function) do
    {:ok,
     %AST.BinaryOp{
       left: context.lower_binary_operand.(left),
       op: Map.fetch!(@binary_ops, function),
       right: context.lower_binary_operand.(right)
     }}
  end

  def lower(%Call{function: :-, args: [expression]}, %Context{} = context),
    do: {:ok, %AST.UnaryOp{op: :neg, expr: context.lower.(expression)}}

  def lower(%Call{function: :+, args: [expression]}, %Context{} = context),
    do: {:ok, context.lower.(expression)}

  def lower(%Call{function: :not, args: [expression]}, %Context{} = context),
    do: {:ok, %AST.UnaryOp{op: :not, expr: context.lower.(expression)}}

  def lower(%Call{function: :abs, args: [expression]}, %Context{} = context),
    do: {:ok, method(context.lower.(expression), :abs)}

  def lower(%Call{function: function, args: [left, right]} = call, %Context{} = context)
      when function in [:min, :max] do
    if integer_type?(context.type_of.(left)) and integer_type?(context.type_of.(right)) do
      {:ok, method(context.lower.(left), function, [context.lower.(right)])}
    else
      unsupported_semantics!(
        call,
        "Kernel.#{function}/2 currently requires statically typed integers"
      )
    end
  end

  def lower(%Call{function: function, args: [value]}, %Context{} = context)
      when function in [:byte_size, :length],
      do: {:ok, cast_i64(method(context.lower.(value), :len))}

  def lower(%Call{function: :map_size, args: [map]} = call, %Context{} = context) do
    case struct_fields(shape_type(context.type_of.(map))) do
      fields when is_list(fields) ->
        evaluated_constant(map, length(fields), context)

      _unknown ->
        unsupported_semantics!(call, "map_size/1 requires a statically typed map or struct")
    end
  end

  def lower(%Call{function: :elem, args: [tuple, index]}, %Context{} = context)
      when is_integer(index) and index >= 0,
      do: {:ok, %AST.Field{receiver: context.lower.(tuple), field: index}}

  def lower(%Call{function: :put_elem, args: [tuple, index, value]} = call, %Context{} = context)
      when is_integer(index) and index >= 0 do
    case tuple_elements(context.type_of.(tuple)) do
      elements when index < length(elements) ->
        tuple_name = :rustq_tuple_value
        tuple_var = %AST.Var{name: tuple_name}

        values =
          elements
          |> Elixir.Enum.with_index()
          |> Elixir.Enum.map(fn
            {type, ^index} -> context.lower_expected.(value, type)
            {_type, field} -> %AST.Field{receiver: tuple_var, field: field}
          end)

        {:ok,
         %AST.BlockExpr{
           body: [
             %AST.Let{pattern: %AST.PatVar{name: tuple_name}, expr: context.lower.(tuple)},
             %AST.Return{expr: %AST.Tuple{values: values}}
           ]
         }}

      _unknown ->
        unsupported_semantics!(
          call,
          "put_elem/3 requires a statically typed tuple and literal index"
        )
    end
  end

  def lower(%Call{function: :tuple_size, args: [tuple]} = call, %Context{} = context) do
    case tuple_elements(shape_type(context.type_of.(tuple))) do
      elements when is_list(elements) ->
        evaluated_constant(tuple, length(elements), context)

      _unknown ->
        unsupported_semantics!(call, "tuple_size/1 requires a statically typed tuple")
    end
  end

  def lower(%Call{function: :is_nil, args: [value]}, %Context{} = context),
    do: {:ok, method(context.lower.(value), :is_none)}

  def lower(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: function}, %TypeContext{}) when function in @comparison_functions,
    do: {:ok, Spec.type(quote(do: boolean()))}

  # Arithmetic on an option or result works on the value its operand propagates.
  def synth(%Call{function: function, args: [left | _rest]}, %TypeContext{} = context)
      when function in [:+, :-, :*, :/, :div, :rem, :abs, :min, :max],
      do: left |> context.type_of.() |> propagated_value() |> type_result()

  def synth(%Call{function: function}, %TypeContext{})
      when function in [:byte_size, :length, :map_size, :tuple_size],
      do: {:ok, Spec.type(quote(do: integer()))}

  def synth(%Call{function: :elem, args: [tuple, index]}, %TypeContext{} = context)
      when is_integer(index) and index >= 0 do
    case tuple_elements(context.type_of.(tuple)) do
      elements when index < length(elements) -> type_result(Elixir.Enum.at(elements, index))
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :put_elem, args: [tuple, _index, _value]}, %TypeContext{} = context),
    do: type_result(context.type_of.(tuple))

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp method(receiver, name, args \\ []),
    do: %AST.MethodCall{receiver: receiver, method: name, args: args}

  defp cast_i64(expression),
    do: %AST.Cast{expr: expression, type: %AST.TypePath{parts: [:i64]}}

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

  defp wrapper_comparison?(left, right, %Context{} = context) do
    wrapper_literal?(left) or wrapper_literal?(right) or
      (wrapper_kind(context.type_of.(left)) != nil and
         wrapper_kind(context.type_of.(left)) == wrapper_kind(context.type_of.(right)))
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
