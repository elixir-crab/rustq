defmodule RustQ.Meta.Lower.Map do
  @moduledoc """
  Lowers `Map` functions for `RustQ.Meta.Lower.Stdlib`, and types such calls.

  On a `HashMap` or `BTreeMap`, `get`, `fetch!`, `has_key?`, `put`, `delete`, `merge`,
  `update/4`, `keys`, `values`, `to_list`, and `new` keep Elixir's meaning: values read out
  are copies, and an update takes the map only at its last use; see
  `RustQ.Meta.Lower.Collection`. On a struct or a map with declared atom keys, `get`,
  `fetch!`, `has_key?`, `put`, and `replace!` read and write its fields.
  """

  use RustQ.Meta.Lower.Stdlib.Lowering

  alias RustQ.Diagnostic
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Type

  @impl true
  def lower(%Call{function: :new, args: []}, %Context{} = context),
    do: lower_new([], context)

  def lower(%Call{args: [map | _]} = call, %Context{} = context) do
    case Collection.keyed_of(map, context) do
      {:map, key, value} -> lower_keyed(call, key, value, context)
      _fields -> lower_fields(call, context)
    end
  end

  # `Map.new/1,2` is a comprehension; see `RustQ.Meta.Desugar`.
  defp lower_new([], _context),
    do: {:ok, A.path_call([:HashMap, :new])}

  defp lower_keyed(%Call{function: :get, args: [map, key]}, key_type, value_type, context) do
    lookup =
      A.method(lowered(map, context), :get, [Collection.borrowed(key, key_type, context)])

    {:ok, Collection.read_out(lookup, value_type)}
  end

  defp lower_keyed(
         %Call{function: :get, args: [map, key, default]},
         key_type,
         value_type,
         context
       ) do
    lookup =
      A.method(lowered(map, context), :get, [Collection.borrowed(key, key_type, context)])

    {:ok, lookup |> Collection.read_out(value_type) |> or_default(default, value_type, context)}
  end

  # A missing key raises in Elixir; indexing panics, which Rustler raises.
  defp lower_keyed(%Call{function: :fetch!, args: [map, key]}, key_type, value_type, context) do
    value = A.index(lowered(map, context), Collection.borrowed(key, key_type, context))

    {:ok, if(Collection.copy?(value_type), do: value, else: A.method(value, :clone))}
  end

  defp lower_keyed(%Call{function: :has_key?, args: [map, key]}, key_type, _value_type, context) do
    {:ok,
     A.method(lowered(map, context), :contains_key, [
       Collection.borrowed(key, key_type, context)
     ])}
  end

  defp lower_keyed(%Call{function: :put, args: [map, key, value]}, key_type, value_type, context) do
    {:ok,
     Collection.updated(
       map,
       fn map ->
         [
           A.stmt(
             A.method(map, :insert, [
               lowered(key, key_type, context),
               lowered(value, value_type, context)
             ])
           )
         ]
       end,
       context
     )}
  end

  defp lower_keyed(%Call{function: :delete, args: [map, key]}, key_type, _value_type, context) do
    {:ok,
     Collection.updated(
       map,
       fn map ->
         [A.stmt(A.method(map, :remove, [Collection.borrowed(key, key_type, context)]))]
       end,
       context
     )}
  end

  defp lower_keyed(%Call{function: :merge, args: [map, other]}, _key_type, _value_type, context) do
    {:ok,
     Collection.updated(
       map,
       fn map ->
         [A.stmt(A.method(map, :extend, [Collection.owned(other, context)]))]
       end,
       context
     )}
  end

  # `update/4` gives a present value to `fun` and stores `default` otherwise, unchanged. Each
  # is its own arm, so both may take what they use.
  defp lower_keyed(
         %Call{function: :update, args: [map, key, default, fun]},
         key_type,
         value_type,
         context
       ) do
    key_name = A.var(:rustq_key)
    {present, updated} = update_arm(fun, value_type, context)

    stored = lowered(default, value_type, context)

    {:ok,
     Collection.updated(
       map,
       fn map ->
         value =
           A.match_expr(A.method(map, :remove, [A.ref(key_name)]), [
             %AST.Arm{pattern: %AST.PatSome{pattern: present}, body: [A.return_stmt(updated)]},
             %AST.Arm{pattern: %AST.PatNone{}, body: [A.return_stmt(stored)]}
           ])

         [
           %AST.Let{
             pattern: %AST.PatVar{name: :rustq_key},
             expr: lowered(key, key_type, context)
           },
           %AST.Let{pattern: %AST.PatVar{name: :rustq_value}, expr: value},
           A.stmt(A.method(map, :insert, [key_name, A.var(:rustq_value)]))
         ]
       end,
       context
     )}
  end

  defp lower_keyed(%Call{function: function, args: [map]}, key_type, value_type, context)
       when function in [:keys, :values] do
    {method, type} = if function == :keys, do: {:keys, key_type}, else: {:values, value_type}

    {:ok,
     lowered(map, context)
     |> A.method(method)
     |> Collection.read_out(type)
     |> A.method(:collect)
     |> collected(Type.vec(type))}
  end

  defp lower_keyed(%Call{function: :to_list, args: [map]}, key_type, value_type, context) do
    {:ok,
     map
     |> Collection.owned(context)
     |> A.method(:into_iter)
     |> A.method(:collect)
     |> collected(Type.vec(Type.tuple([key_type, value_type])))}
  end

  defp lower_keyed(%Call{}, _key_type, _value_type, _context), do: :unsupported

  # An empty collection is the value's default, as clippy prefers.
  defp or_default(option, [], _value_type, _context), do: A.method(option, :unwrap_or_default)

  defp or_default(option, {:%{}, _, []}, _value_type, _context),
    do: A.method(option, :unwrap_or_default)

  defp or_default(option, default, value_type, context),
    do: A.method(option, :unwrap_or, [lowered(default, value_type, context)])

  # The present value's pattern, and `fun`'s result for it: a function's body with its argument
  # bound to the value, or a captured function called with it.
  defp update_arm({:fn, _, [{:->, _, [[{name, _, ast_context}], body]}]}, value_type, context)
       when is_atom(name) and is_atom(ast_context) do
    bound = %{context | env: %{context.env | vars: Map.put(context.env.vars, name, value_type)}}
    {%AST.PatVar{name: name}, lowered(body, value_type, bound)}
  end

  defp update_arm({:&, _, [{:/, _, [function, 1]}]}, _value_type, context) do
    %AST.Path{} = path = capture(function, context)
    {%AST.PatVar{name: :rustq_present}, %AST.PathCall{path: path, args: [A.var(:rustq_present)]}}
  end

  defp update_arm(other, _value_type, _context) do
    Diagnostic.lower(
      :unsupported_map_update_function,
      other,
      "unsupported Map.update function in defrust",
      suggestion: "Use a one-argument anonymous function with a named argument, or a capture."
    )
  end

  defp collected(%AST.MethodCall{method: :collect} = call, %Type{ast: type}),
    do: %{call | generics: [type]}

  defp lower_fields(%Call{function: :get, args: [map, key]} = call, %Context{} = context)
       when is_atom(key),
       do: lower_get(call, map, key, %AST.None{}, false, context)

  defp lower_fields(%Call{function: :get, args: [map, key, default]} = call, %Context{} = context)
       when is_atom(key),
       do: lower_get(call, map, key, lowered(default, context), true, context)

  defp lower_fields(%Call{function: :fetch!, args: [map, key]} = call, %Context{} = context)
       when is_atom(key) do
    with %Type{} = map_type <- map_type(type_of(map, context)),
         %Type{} <- Type.field_type(map_type, key) do
      {:ok, A.field(lowered(map, context), key)}
    else
      _unknown -> unsupported_field!(call)
    end
  end

  defp lower_fields(%Call{function: :has_key?, args: [map, key]} = call, %Context{} = context)
       when is_atom(key) do
    case map_type(shape_type(type_of(map, context))) do
      %Type{} = type ->
        present? = match?(%Type{}, Type.field_type(type, key))

        evaluated_constant(map, present?, context)

      nil ->
        unsupported_field!(call)
    end
  end

  defp lower_fields(
         %Call{function: function, args: [map, key, value]} = call,
         %Context{} = context
       )
       when function in [:put, :replace!] and is_atom(key) do
    with %Type{} = map_type <- map_type(type_of(map, context)),
         %Type{} = field_type <- Type.field_type(map_type, key) do
      name = :rustq_map_value
      variable = A.var(name)

      {:ok,
       A.block_expr([
         %AST.Let{
           pattern: %AST.PatVar{name: name},
           expr: lowered(map, context),
           mutable: true
         },
         A.assign(A.field(variable, key), lowered(value, field_type, context)),
         A.return_stmt(variable)
       ])}
    else
      _unknown -> unsupported_field!(call)
    end
  end

  defp lower_fields(%Call{}, %Context{}), do: :unsupported

  @impl true
  def synth(%Call{function: :new}, %TypeContext{}), do: :unsupported

  def synth(%Call{args: [map | _]} = call, %TypeContext{} = context) do
    case Collection.keyed(type_of(map, context)) do
      {:map, key, value} -> synth_keyed(call, map, key, value, context)
      _fields -> synth_fields(call, context)
    end
  end

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp synth_keyed(%Call{function: :get, args: [_, _]}, _map, _key_type, value, _context),
    do: {:ok, Type.option(value)}

  defp synth_keyed(%Call{function: function}, _map, _key_type, value, _context)
       when function in [:get, :fetch!],
       do: {:ok, value}

  defp synth_keyed(%Call{function: :has_key?}, _map, _key_type, _value, _context),
    do: {:ok, RustQ.Spec.type(quote(do: boolean()))}

  defp synth_keyed(%Call{function: function}, map, _key_type, _value, context)
       when function in [:put, :delete, :merge, :update] do
    case type_of(map, context) do
      %Type{kind: kind} = type when kind in [:ref, :mut_ref] -> type_result(Type.ref_inner(type))
      type -> type_result(type)
    end
  end

  defp synth_keyed(%Call{function: :keys}, _map, key, _value, _context), do: {:ok, Type.vec(key)}

  defp synth_keyed(%Call{function: :values}, _map, _key, value, _context),
    do: {:ok, Type.vec(value)}

  defp synth_keyed(%Call{function: :to_list}, _map, key, value, _context),
    do: {:ok, Type.vec(Type.tuple([key, value]))}

  defp synth_keyed(%Call{}, _map, _key, _value, _context), do: :unsupported

  defp synth_fields(%Call{function: function, args: [map, key | _rest]}, %TypeContext{} = context)
       when function in [:get, :fetch!] and is_atom(key) do
    with %Type{} = map_type <- map_type(type_of(map, context)),
         %Type{} = field_type <- Type.field_type(map_type, key) do
      {:ok, field_type}
    else
      _unknown -> :unsupported
    end
  end

  defp synth_fields(%Call{function: :has_key?}, %TypeContext{}),
    do: {:ok, RustQ.Spec.type(quote(do: boolean()))}

  defp synth_fields(
         %Call{function: function, args: [map, _key, _value]},
         %TypeContext{} = context
       )
       when function in [:put, :replace!],
       do: type_result(type_of(map, context))

  defp synth_fields(%Call{}, %TypeContext{}), do: :unsupported

  defp lower_get(call, map, key, default, evaluate_default?, context) do
    case map_type(type_of(map, context)) do
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
     A.block_expr([
       %AST.Let{pattern: %AST.PatVar{name: name}, expr: lowered(map, context)},
       %AST.Let{pattern: %AST.PatWildcard{}, expr: default},
       A.return_stmt(A.field(A.var(name), key))
     ])}
  end

  defp lower_present_get(map, key, _default, false, context),
    do: {:ok, A.field(lowered(map, context), key)}

  defp lower_missing_get(map, default, context) do
    {:ok,
     A.block_expr([
       %AST.Let{pattern: %AST.PatWildcard{}, expr: lowered(map, context)},
       A.return_stmt(default)
     ])}
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
