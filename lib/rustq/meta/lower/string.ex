defmodule RustQ.Meta.Lower.String do
  @moduledoc """
  Lowers `String` functions whose Rust counterparts keep their semantics, such as
  `String.replace/3` and `String.trim/1` for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  use RustQ.Meta.Lower.Stdlib.Lowering

  alias RustQ.Meta.Type
  alias RustQ.Spec

  @predicate_methods %{
    starts_with?: :starts_with,
    ends_with?: :ends_with,
    contains?: :contains
  }

  @impl true
  def lower(%Call{function: function, args: [string, pattern]}, %Context{} = context)
      when is_map_key(@predicate_methods, function) do
    {:ok,
     A.method(lowered(string, context), Map.fetch!(@predicate_methods, function), [
       A.ref(lowered(pattern, context))
     ])}
  end

  def lower(%Call{function: :trim, args: [string]}, %Context{} = context),
    do:
      {:ok,
       string
       |> lowered(context)
       |> A.method(:trim)
       |> A.method(:to_string)}

  def lower(
        %Call{function: :replace, args: [string, pattern, replacement]},
        %Context{} = context
      ),
      do:
        {:ok,
         A.method(lowered(string, context), :replace, [
           string_slice(pattern, context),
           string_slice(replacement, context)
         ])}

  def lower(%Call{function: :duplicate, args: [string, count]} = call, %Context{} = context) do
    case nonnegative_count(count, context) do
      {:ok, lowered_count} -> {:ok, A.method(lowered(string, context), :repeat, [lowered_count])}
      :unsupported -> unsupported_count!(call)
    end
  end

  def lower(%Call{function: :valid?, args: [string]}, %Context{} = context) do
    case type_of(string, context) do
      %Type{} = type when type.kind == :binary ->
        bytes = A.method(lowered(string, context), :as_slice)

        {:ok,
         %AST.PathCall{path: A.path([:std, :str, :from_utf8]), args: [bytes]}
         |> then(&%AST.MethodCall{receiver: &1, method: :is_ok, args: []})}

      %Type{} = type ->
        if Type.category(type) == :string,
          do: {:ok, A.lit(true)},
          else: :unsupported

      _unknown ->
        :unsupported
    end
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @impl true
  def synth(%Call{function: function}, %TypeContext{})
      when function in [:starts_with?, :ends_with?, :contains?, :valid?],
      do: {:ok, Spec.type(quote(do: boolean()))}

  def synth(%Call{function: function}, %TypeContext{})
      when function in [:trim, :replace, :duplicate],
      do: {:ok, Spec.type(quote(do: String.t()))}

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp string_slice(value, context) when is_binary(value), do: lowered(value, context)
  defp string_slice(value, context), do: A.method(lowered(value, context), :as_str)

  @spec unsupported_count!(Call.t()) :: no_return()
  defp unsupported_count!(%Call{source: source}) do
    RustQ.Diagnostic.lower(
      :unsupported_string_count_semantics,
      source,
      "String.duplicate/2 requires a non-negative literal or unsigned count type",
      suggestion: "Use R.usize() for dynamic non-negative native counts."
    )
  end
end
