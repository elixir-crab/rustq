defmodule RustQ.Meta.Lower.List do
  @moduledoc """
  Lowers `List.duplicate/2`, `List.flatten/1`, and `List.wrap/1` for `RustQ.Meta.Lower.Stdlib`,
  and types such calls.
  """

  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: function, args: [list]}, %Context{} = context)
      when function in [:first, :last] do
    terminal = if function == :first, do: :next, else: :last

    {:ok,
     list
     |> context.lower.()
     |> method(:into_iter)
     |> method(terminal)}
  end

  def lower(%Call{function: function, args: [list, default]}, %Context{} = context)
      when function in [:first, :last] do
    terminal = if function == :first, do: :next, else: :last

    {:ok,
     list
     |> context.lower.()
     |> method(:into_iter)
     |> method(terminal)
     |> method(:unwrap_or, [context.lower.(default)])}
  end

  def lower(%Call{function: :wrap, args: [nil]}, %Context{}),
    do: {:ok, %AST.VecLiteral{values: []}}

  def lower(%Call{function: :wrap, args: [value]}, %Context{} = context) do
    case context.type_of.(value) do
      %Type{} = type ->
        if collection_inner(type),
          do: {:ok, context.lower.(value)},
          else: {:ok, %AST.VecLiteral{values: [context.lower.(value)]}}

      _unknown ->
        :unsupported
    end
  end

  def lower(%Call{function: :duplicate, args: [value, count]}, %Context{} = context) do
    case Stdlib.nonnegative_count(count, context) do
      {:ok, lowered_count} ->
        {:ok,
         %AST.PathCall{
           path: %AST.Path{parts: [:std, :iter, :repeat]},
           args: [context.lower.(value)]
         }
         |> method(:take, [lowered_count])
         |> method(:collect)}

      :unsupported ->
        :unsupported
    end
  end

  def lower(%Call{function: :flatten, args: [list]}, %Context{} = context) do
    depth = flatten_depth(context.type_of.(list))

    if is_integer(depth) and depth > 0 do
      iterator = list |> context.lower.() |> method(:into_iter)

      {:ok, iterator |> flatten_iterator(depth) |> method(:collect)}
    else
      :unsupported
    end
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: function, args: [list]}, %TypeContext{} = context)
      when function in [:first, :last] do
    case collection_inner(context.type_of.(list)) do
      %Type{} = inner -> {:ok, Type.option(inner)}
      nil -> :unsupported
    end
  end

  def synth(%Call{function: function, args: [_list, default]}, %TypeContext{} = context)
      when function in [:first, :last],
      do: type_result(context.type_of.(default))

  def synth(%Call{function: :wrap, args: [value]}, %TypeContext{} = context) do
    case context.type_of.(value) do
      %Type{} = type ->
        {:ok,
         if(collection_inner(type), do: Type.vec(collection_inner(type)), else: Type.vec(type))}

      nil ->
        :unsupported
    end
  end

  def synth(%Call{function: :duplicate, args: [value, _count]}, %TypeContext{} = context) do
    case context.type_of.(value) do
      %Type{} = type -> {:ok, Type.vec(type)}
      nil -> :unsupported
    end
  end

  def synth(%Call{function: :flatten, args: [list]}, %TypeContext{} = context) do
    case innermost_type(context.type_of.(list)) do
      %Type{} = inner -> {:ok, Type.vec(inner)}
      nil -> :unsupported
    end
  end

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp flatten_iterator(iterator, 1), do: iterator

  defp flatten_iterator(iterator, depth) do
    Elixir.Enum.reduce(1..(depth - 1), iterator, fn _, acc -> method(acc, :flatten) end)
  end

  defp flatten_depth(type), do: do_flatten_depth(type, 0)

  defp do_flatten_depth(%Type{} = type, depth) do
    case collection_inner(type) do
      %Type{} = inner -> do_flatten_depth(inner, depth + 1)
      nil -> depth
    end
  end

  defp do_flatten_depth(_type, _depth), do: nil

  defp innermost_type(%Type{} = type) do
    case collection_inner(type) do
      %Type{} = inner -> innermost_type(inner)
      nil -> type
    end
  end

  defp innermost_type(_type), do: nil

  defp collection_inner(%Type{} = type), do: Type.vec_inner(type) || Type.slice_inner(type)
  defp collection_inner(_type), do: nil

  defp type_result(%Type{} = type), do: {:ok, type}
  defp type_result(_type), do: :unsupported

  defp method(receiver, name, args \\ []),
    do: %AST.MethodCall{receiver: receiver, method: name, args: args}
end
