defmodule RustQ.Meta.Lower.Range do
  @moduledoc """
  Lowers ranges and `in` over them for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Spec

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :.., args: [start, stop]} = call, %Context{} = context) do
    if ascending_literal_range?(start, stop) do
      {:ok,
       %AST.Range{
         start: context.lower.(start),
         stop: context.lower.(stop),
         inclusive: true
       }}
    else
      Diagnostic.lower(
        :unsupported_stdlib_semantics,
        call.source,
        "generated Rust ranges currently require ascending integer literal bounds",
        suggestion: "Use an explicit Rust adapter for dynamic or descending ranges."
      )
    end
  end

  def lower(%Call{function: :in, args: [value, collection]}, %Context{} = context) do
    receiver =
      case context.lower.(collection) do
        %AST.Range{} = range -> A.block_expr([A.return_stmt(range)])
        expression -> expression
      end

    {:ok, A.method(receiver, :contains, [A.ref(context.lower.(value))])}
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, term()} | :unsupported
  def synth(%Call{function: :in}, %TypeContext{}),
    do: {:ok, Spec.type(quote(do: boolean()))}

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp ascending_literal_range?(start, stop)
       when is_integer(start) and is_integer(stop) and start <= stop,
       do: true

  defp ascending_literal_range?(_start, _stop), do: false
end
