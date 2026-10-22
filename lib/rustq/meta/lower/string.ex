defmodule RustQ.Meta.Lower.String do
  @moduledoc """
  Lowers `String` functions whose Rust counterparts keep their semantics, such as
  `String.replace/3` and `String.trim/1` for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Spec

  @predicate_methods %{
    starts_with?: :starts_with,
    ends_with?: :ends_with,
    contains?: :contains
  }

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: function, args: [string, pattern]}, %Context{} = context)
      when is_map_key(@predicate_methods, function) do
    {:ok,
     %AST.MethodCall{
       receiver: context.lower.(string),
       method: Map.fetch!(@predicate_methods, function),
       args: [%AST.Ref{expr: context.lower.(pattern)}]
     }}
  end

  def lower(%Call{function: :trim, args: [string]}, %Context{} = context),
    do:
      {:ok,
       string
       |> context.lower.()
       |> method(:trim)
       |> method(:to_string)}

  def lower(
        %Call{function: :replace, args: [string, pattern, replacement]},
        %Context{} = context
      ),
      do:
        {:ok,
         method(context.lower.(string), :replace, [
           string_slice(pattern, context),
           string_slice(replacement, context)
         ])}

  def lower(%Call{function: :duplicate, args: [string, count]} = call, %Context{} = context) do
    case Stdlib.nonnegative_count(count, context) do
      {:ok, lowered_count} -> {:ok, method(context.lower.(string), :repeat, [lowered_count])}
      :unsupported -> unsupported_count!(call)
    end
  end

  def lower(%Call{function: :valid?, args: [string]}, %Context{} = context) do
    case context.type_of.(string) do
      %Type{} = type when type.kind == :binary ->
        bytes = %AST.MethodCall{receiver: context.lower.(string), method: :as_slice, args: []}

        {:ok,
         %AST.PathCall{path: %AST.Path{parts: [:std, :str, :from_utf8]}, args: [bytes]}
         |> then(&%AST.MethodCall{receiver: &1, method: :is_ok, args: []})}

      %Type{} = type ->
        if Type.category(type) == :string,
          do: {:ok, %AST.Literal{value: true}},
          else: :unsupported

      _unknown ->
        :unsupported
    end
  end

  def lower(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, term()} | :unsupported
  def synth(%Call{function: function}, %TypeContext{})
      when function in [:starts_with?, :ends_with?, :contains?, :valid?],
      do: {:ok, Spec.type(quote(do: boolean()))}

  def synth(%Call{function: function}, %TypeContext{})
      when function in [:trim, :replace, :duplicate],
      do: {:ok, Spec.type(quote(do: String.t()))}

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp string_slice(value, context) when is_binary(value), do: context.lower.(value)
  defp string_slice(value, context), do: method(context.lower.(value), :as_str)

  defp method(receiver, name, args \\ []),
    do: %AST.MethodCall{receiver: receiver, method: name, args: args}

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
