defmodule RustQ.Meta.Lower.Map do
  @moduledoc false

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :get, args: [map, key]} = call, %Context{} = context)
      when is_atom(key),
      do: lower_get(call, map, key, %AST.None{}, false, context)

  def lower(%Call{function: :get, args: [map, key, default]} = call, %Context{} = context)
      when is_atom(key),
      do: lower_get(call, map, key, context.lower.(default), true, context)

  def lower(%Call{function: :fetch!, args: [map, key]} = call, %Context{} = context)
      when is_atom(key) do
    with %Type{} = map_type <- map_type(context.type_of.(map)),
         %Type{} <- Type.field_type(map_type, key) do
      {:ok, %AST.Field{receiver: context.lower.(map), field: key}}
    else
      _unknown -> unsupported_field!(call)
    end
  end

  def lower(%Call{function: :has_key?, args: [map, key]} = call, %Context{} = context)
      when is_atom(key) do
    case map_type(Stdlib.shape_type(context.type_of.(map))) do
      %Type{} = type ->
        present? = match?(%Type{}, Type.field_type(type, key))

        Stdlib.evaluated_constant(map, present?, context)

      nil ->
        unsupported_field!(call)
    end
  end

  def lower(%Call{function: function, args: [map, key, value]} = call, %Context{} = context)
      when function in [:put, :replace!] and is_atom(key) do
    with %Type{} = map_type <- map_type(context.type_of.(map)),
         %Type{} = field_type <- Type.field_type(map_type, key) do
      name = :rustq_map_value
      variable = %AST.Var{name: name}

      {:ok,
       %AST.BlockExpr{
         body: [
           %AST.Let{
             pattern: %AST.PatVar{name: name},
             expr: context.lower.(map),
             mutable: true
           },
           %AST.Assign{
             target: %AST.Field{receiver: variable, field: key},
             expr: context.lower_expected.(value, field_type)
           },
           %AST.Return{expr: variable}
         ]
       }}
    else
      _unknown -> unsupported_field!(call)
    end
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: function, args: [map, key | _rest]}, %TypeContext{} = context)
      when function in [:get, :fetch!] and is_atom(key) do
    with %Type{} = map_type <- map_type(context.type_of.(map)),
         %Type{} = field_type <- Type.field_type(map_type, key) do
      {:ok, field_type}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :has_key?}, %TypeContext{}),
    do: {:ok, RustQ.Spec.type(quote(do: boolean()))}

  def synth(%Call{function: function, args: [map, _key, _value]}, %TypeContext{} = context)
      when function in [:put, :replace!],
      do: type_result(context.type_of.(map))

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp lower_get(call, map, key, default, evaluate_default?, context) do
    case map_type(context.type_of.(map)) do
      %Type{} = type -> lower_typed_get(type, map, key, default, evaluate_default?, context)
      nil -> unsupported_field!(call)
    end
  end

  defp lower_typed_get(type, map, key, default, evaluate_default?, context) do
    case Type.field_type(type, key) do
      %Type{} -> lower_present_get(map, key, default, evaluate_default?, context)
      nil -> lower_missing_get(map, default, context)
    end
  end

  defp lower_present_get(map, key, default, true, context) do
    name = :rustq_map_get_value

    {:ok,
     %AST.BlockExpr{
       body: [
         %AST.Let{pattern: %AST.PatVar{name: name}, expr: context.lower.(map)},
         %AST.Let{pattern: %AST.PatWildcard{}, expr: default},
         %AST.Return{expr: %AST.Field{receiver: %AST.Var{name: name}, field: key}}
       ]
     }}
  end

  defp lower_present_get(map, key, _default, false, context),
    do: {:ok, %AST.Field{receiver: context.lower.(map), field: key}}

  defp lower_missing_get(map, default, context) do
    {:ok,
     %AST.BlockExpr{
       body: [
         %AST.Let{pattern: %AST.PatWildcard{}, expr: context.lower.(map)},
         %AST.Return{expr: default}
       ]
     }}
  end

  defp map_type(%Type{kind: :alias, meta: %{target: %Type{} = target}}), do: map_type(target)
  defp map_type(%Type{kind: :struct} = type), do: type
  defp map_type(%Type{} = type), do: type |> Type.ref_inner() |> map_type()
  defp map_type(_type), do: nil

  defp type_result(%Type{} = type), do: {:ok, type}
  defp type_result(_type), do: :unsupported

  @spec unsupported_field!(Call.t()) :: no_return()
  defp unsupported_field!(%Call{source: source}) do
    Diagnostic.lower(
      :unsupported_typed_map_field,
      source,
      "typed Map lowering requires a statically known atom key present in the map or struct type",
      suggestion: "Declare the field in @type or use an explicit Rust map adapter."
    )
  end
end
