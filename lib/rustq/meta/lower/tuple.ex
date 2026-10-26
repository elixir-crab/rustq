defmodule RustQ.Meta.Lower.Tuple do
  @moduledoc """
  Lowers `Tuple.to_list/1` for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :to_list, args: [tuple]} = call, %Context{} = context) do
    with elements when is_list(elements) <- tuple_elements(context.type_of.(tuple)),
         true <- homogeneous?(elements) do
      name = :rustq_tuple_value
      variable = A.var(name)

      values =
        elements
        |> Elixir.Enum.with_index()
        |> Elixir.Enum.map(fn {_type, index} ->
          %AST.Field{receiver: variable, field: index}
        end)

      {:ok,
       A.block_expr([
         %AST.Let{pattern: %AST.PatVar{name: name}, expr: context.lower.(tuple)},
         A.return_stmt(%AST.VecLiteral{values: values})
       ])}
    else
      _unknown -> unsupported_tuple!(call)
    end
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: :to_list, args: [tuple]}, %TypeContext{} = context) do
    with [first | _rest] = elements <- tuple_elements(context.type_of.(tuple)),
         true <- homogeneous?(elements) do
      {:ok, Type.vec(first)}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp tuple_elements(%Type{kind: :tuple, meta: %{elements: elements}}), do: elements
  defp tuple_elements(_type), do: nil

  defp homogeneous?([]), do: true

  defp homogeneous?([first | rest]),
    do: Elixir.Enum.all?(rest, &Type.compatible?(&1, first))

  @spec unsupported_tuple!(Call.t()) :: no_return()
  defp unsupported_tuple!(%Call{source: source}) do
    Diagnostic.lower(
      :unsupported_tuple_to_list,
      source,
      "Tuple.to_list/1 requires a statically typed homogeneous tuple",
      suggestion: "Use an explicit tuple transformation when element types differ."
    )
  end
end
