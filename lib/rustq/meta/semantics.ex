defmodule RustQ.Meta.Semantics do
  @moduledoc """
  Argument types std methods take that their signatures alone do not say, as
  `binary_search_by_key` borrowing the key its closure reads.
  """

  alias RustQ.Meta.Type

  @spec binary_search_by_key_argument_types(Type.t(), Macro.t()) :: [Type.t() | nil] | nil
  def binary_search_by_key_argument_types(%Type{} = receiver_type, closure) do
    with %Type{} = item_type <- Type.slice_inner(receiver_type),
         %Type{} = key_type <- closure_field_type(closure, item_type) do
      [Type.ref(key_type), nil]
    end
  end

  defp closure_field_type(
         {:fn, _meta, [{:->, _, [[{name, _, context}], body]}]},
         %Type{} = item_type
       )
       when is_atom(name) and is_atom(context) do
    case body do
      {{:., _, [{^name, _, body_context}, field]}, _meta, []}
      when is_atom(body_context) and is_atom(field) ->
        Type.field_type(item_type, field)

      _other ->
        nil
    end
  end

  defp closure_field_type(_closure, _item_type), do: nil
end
