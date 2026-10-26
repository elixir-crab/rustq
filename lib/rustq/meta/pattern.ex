defmodule RustQ.Meta.Pattern do
  @moduledoc """
  Helpers for reading quoted Elixir patterns, such as the elements of a tuple pattern of any
  size.
  """

  @spec tuple_elements(Macro.t()) :: [Macro.t()] | nil
  def tuple_elements({:{}, _, elements}) when is_list(elements), do: elements

  def tuple_elements(pattern) when is_tuple(pattern) and tuple_size(pattern) != 3,
    do: Tuple.to_list(pattern)

  def tuple_elements(_pattern), do: nil

  @doc "The variables a pattern binds, in order, leaving out pinned and underscored ones."
  @spec variables(Macro.t()) :: [{atom(), keyword(), atom()}]
  def variables(pattern) do
    {_pattern, variables} =
      Macro.prewalk(pattern, [], fn
        {:^, _meta, _args}, variables ->
          {:pinned, variables}

        {name, meta, context} = variable, variables when is_atom(name) and is_atom(context) ->
          if name |> Atom.to_string() |> String.starts_with?("_"),
            do: {variable, variables},
            else: {variable, [{name, meta, context} | variables]}

        other, variables ->
          {other, variables}
      end)

    variables |> Enum.reverse() |> Enum.uniq_by(fn {name, _meta, context} -> {name, context} end)
  end
end
