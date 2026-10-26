defmodule RustQ.Meta.Lower.Range do
  @moduledoc """
  Lowers ranges and `in` over them for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  use RustQ.Meta.Lower.Stdlib.Lowering

  alias RustQ.Diagnostic
  alias RustQ.Spec

  @impl true
  def lower(%Call{function: :.., args: [start, stop]} = call, %Context{} = context) do
    if ascending_literal_range?(start, stop) do
      {:ok,
       %AST.Range{
         start: lowered(start, context),
         stop: lowered(stop, context),
         inclusive: true
       }}
    else
      Diagnostic.lower(
        :unsupported_stdlib_semantics,
        call.source,
        "generated Rust ranges currently require ascending integer literal bounds",
        suggestion: "Count up with an explicit step, as `first..last//1`, for dynamic bounds."
      )
    end
  end

  # With a positive step, a range counts up and is empty when it ends below its start, as
  # Rust's `start..=stop` is, so its bounds need not be literals.
  def lower(%Call{function: :..//, args: [start, stop, step]} = call, %Context{} = context) do
    if is_integer(step) and step > 0 do
      range = %AST.Range{
        start: lowered(start, context),
        stop: lowered(stop, context),
        inclusive: true
      }

      {:ok,
       if(step == 1,
         do: range,
         else: A.method(A.block_expr([A.return_stmt(range)]), :step_by, [A.lit(step)])
       )}
    else
      Diagnostic.lower(
        :unsupported_stdlib_semantics,
        call.source,
        "generated Rust ranges with a step require a positive integer literal step",
        suggestion: "Count up with a positive step, as `first..last//1`."
      )
    end
  end

  def lower(%Call{function: :in, args: [value, collection]}, %Context{} = context) do
    receiver =
      case lowered(collection, context) do
        %AST.Range{} = range -> A.block_expr([A.return_stmt(range)])
        expression -> expression
      end

    {:ok, A.method(receiver, :contains, [A.ref(lowered(value, context))])}
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @impl true
  def synth(%Call{function: :in}, %TypeContext{}),
    do: {:ok, Spec.type(quote(do: boolean()))}

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp ascending_literal_range?(start, stop)
       when is_integer(start) and is_integer(stop) and start <= stop,
       do: true

  defp ascending_literal_range?(_start, _stop), do: false
end
