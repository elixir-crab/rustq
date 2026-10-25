defmodule RustQ.Meta.Lower.Map do
  @moduledoc """
  Lowers `Map` functions for `RustQ.Meta.Lower.Stdlib`, and types such calls.

  On a `HashMap` or `BTreeMap`, `get`, `fetch!`, `has_key?`, `put`, `delete`, `merge`,
  `update/4`, `keys`, `values`, `to_list`, and `new` keep Elixir's meaning: values read out
  are copies, and an update takes the map only at its last use; see
  `RustQ.Meta.Lower.Collection`. On a struct or a map with declared atom keys, `get`,
  `fetch!`, `has_key?`, `put`, and `replace!` read and write its fields.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :new, args: args}, %Context{} = context),
    do: lower_new(args, context)

  def lower(%Call{args: [map | _]} = call, %Context{} = context) do
    case Collection.keyed_of(map, context) do
      {:map, key, value} -> lower_keyed(call, key, value, context)
      _fields -> lower_fields(call, context)
    end
  end

  # `Map.new/0,1,2` builds what the comprehension `for item <- enumerable, into: %{}` would.
  defp lower_new([], _context),
    do: {:ok, %AST.PathCall{path: %AST.Path{parts: [:HashMap, :new]}, args: []}}

  defp lower_new([enumerable | transform], context),
    do: {:ok, collect(comprehension(enumerable, transform, quote(do: HashMap.new())), context)}

  @doc "Lowers a comprehension collecting into the type the call is expected to give, if known."
  @spec collect(Macro.t(), Context.t()) :: AST.expr()
  def collect(comprehension, %Context{expected: %Type{} = expected} = context),
    do: context.lower_expected.(comprehension, expected)

  def collect(comprehension, %Context{} = context), do: context.lower.(comprehension)

  @doc """
  The comprehension collecting `enumerable` into `into`, through the one-argument function
  `transform` gives, as `Map.new/1,2`, `MapSet.new/1,2`, and `Enum.into/2` build.
  """
  @spec comprehension(Macro.t(), [Macro.t()], Macro.t()) :: Macro.t()
  def comprehension(enumerable, [], into),
    do: quote(do: for(item <- unquote(enumerable), into: unquote(into), do: item))

  def comprehension(enumerable, [{:fn, _, [{:->, _, [[pattern], body]}]}], into),
    do:
      quote(
        do: for(unquote(pattern) <- unquote(enumerable), into: unquote(into), do: unquote(body))
      )

  def comprehension(enumerable, [{:&, _, [{:/, _, [function, 1]}]}], into) do
    quote do
      for item <- unquote(enumerable), into: unquote(into), do: unquote(function)(item)
    end
  end

  defp lower_keyed(%Call{function: :get, args: [map, key]}, key_type, value_type, context) do
    lookup =
      Collection.call(context.lower.(map), :get, [Collection.borrowed(key, key_type, context)])

    {:ok, Collection.read_out(lookup, value_type)}
  end

  defp lower_keyed(
         %Call{function: :get, args: [map, key, default]},
         key_type,
         value_type,
         context
       ) do
    lookup =
      Collection.call(context.lower.(map), :get, [Collection.borrowed(key, key_type, context)])

    {:ok,
     lookup
     |> Collection.read_out(value_type)
     |> Collection.call(:unwrap_or, [context.lower_expected.(default, value_type)])}
  end

  # A missing key raises in Elixir; indexing panics, which Rustler raises.
  defp lower_keyed(%Call{function: :fetch!, args: [map, key]}, key_type, value_type, context) do
    value = %AST.Index{
      receiver: context.lower.(map),
      index: Collection.borrowed(key, key_type, context)
    }

    {:ok, if(Collection.copy?(value_type), do: value, else: Collection.call(value, :clone))}
  end

  defp lower_keyed(%Call{function: :has_key?, args: [map, key]}, key_type, _value_type, context) do
    {:ok,
     Collection.call(context.lower.(map), :contains_key, [
       Collection.borrowed(key, key_type, context)
     ])}
  end

  defp lower_keyed(%Call{function: :put, args: [map, key, value]}, key_type, value_type, context) do
    {:ok,
     Collection.updated(
       map,
       fn map ->
         [
           Collection.statement(map, :insert, [
             context.lower_expected.(key, key_type),
             context.lower_expected.(value, value_type)
           ])
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
         [Collection.statement(map, :remove, [Collection.borrowed(key, key_type, context)])]
       end,
       context
     )}
  end

  defp lower_keyed(%Call{function: :merge, args: [map, other]}, _key_type, _value_type, context) do
    {:ok,
     Collection.updated(
       map,
       fn map ->
         [Collection.statement(map, :extend, [Collection.owned(other, context)])]
       end,
       context
     )}
  end

  # `update/4` gives a present value to `fun` and stores `default` otherwise, unchanged.
  defp lower_keyed(
         %Call{function: :update, args: [map, key, default, fun]},
         key_type,
         value_type,
         context
       ) do
    key_name = %AST.Var{name: :rustq_key}
    value_name = %AST.Var{name: :rustq_value}

    {:ok,
     Collection.updated(
       map,
       fn map ->
         updated =
           map
           |> Collection.call(:remove, [%AST.Ref{expr: key_name}])
           |> Collection.call(:map, [update_function(fun, value_type, context)])
           |> Collection.call(:unwrap_or, [context.lower_expected.(default, value_type)])

         [
           %AST.Let{
             pattern: %AST.PatVar{name: :rustq_key},
             expr: context.lower_expected.(key, key_type)
           },
           %AST.Let{pattern: %AST.PatVar{name: :rustq_value}, expr: updated},
           Collection.statement(map, :insert, [key_name, value_name])
         ]
       end,
       context
     )}
  end

  defp lower_keyed(%Call{function: function, args: [map]}, key_type, value_type, context)
       when function in [:keys, :values] do
    {method, type} = if function == :keys, do: {:keys, key_type}, else: {:values, value_type}

    {:ok,
     context.lower.(map)
     |> Collection.call(method)
     |> Collection.read_out(type)
     |> Collection.call(:collect)
     |> collected(Type.vec(type))}
  end

  defp lower_keyed(%Call{function: :to_list, args: [map]}, key_type, value_type, context) do
    {:ok,
     map
     |> Collection.owned(context)
     |> Collection.call(:into_iter)
     |> Collection.call(:collect)
     |> collected(Type.vec(Type.tuple([key_type, value_type])))}
  end

  defp lower_keyed(%Call{}, _key_type, _value_type, _context), do: :unsupported

  defp update_function({:fn, _, [{:->, _, [[argument], body]}]}, value_type, context),
    do: context.lower_closure.([{:__rustq_typed_arg__, [], [argument, value_type]}], body)

  defp update_function({:&, _, [{:/, _, [function, 1]}]}, _value_type, context),
    do: context.lower_capture.(function)

  defp update_function(other, _value_type, _context) do
    Diagnostic.lower(
      :unsupported_map_update_function,
      other,
      "unsupported Map.update function in defrust",
      suggestion: "Use a one-argument anonymous function or a named one-argument capture."
    )
  end

  defp collected(%AST.MethodCall{method: :collect} = call, %Type{ast: type}),
    do: %{call | generics: [type]}

  defp lower_fields(%Call{function: :get, args: [map, key]} = call, %Context{} = context)
       when is_atom(key),
       do: lower_get(call, map, key, %AST.None{}, false, context)

  defp lower_fields(%Call{function: :get, args: [map, key, default]} = call, %Context{} = context)
       when is_atom(key),
       do: lower_get(call, map, key, context.lower.(default), true, context)

  defp lower_fields(%Call{function: :fetch!, args: [map, key]} = call, %Context{} = context)
       when is_atom(key) do
    with %Type{} = map_type <- map_type(context.type_of.(map)),
         %Type{} <- Type.field_type(map_type, key) do
      {:ok, %AST.Field{receiver: context.lower.(map), field: key}}
    else
      _unknown -> unsupported_field!(call)
    end
  end

  defp lower_fields(%Call{function: :has_key?, args: [map, key]} = call, %Context{} = context)
       when is_atom(key) do
    case map_type(Stdlib.shape_type(context.type_of.(map))) do
      %Type{} = type ->
        present? = match?(%Type{}, Type.field_type(type, key))

        Stdlib.evaluated_constant(map, present?, context)

      nil ->
        unsupported_field!(call)
    end
  end

  defp lower_fields(
         %Call{function: function, args: [map, key, value]} = call,
         %Context{} = context
       )
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

  defp lower_fields(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: :new, args: [enumerable]}, %TypeContext{} = context) do
    with %Type{} = type <- context.type_of.(enumerable),
         %Type{kind: :tuple, meta: %{elements: [key, value]}} <-
           Type.vec_inner(type) || Type.slice_inner(type) do
      {:ok, Collection.map(key, value)}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :new}, %TypeContext{}), do: :unsupported

  def synth(%Call{args: [map | _]} = call, %TypeContext{} = context) do
    case Collection.keyed(context.type_of.(map)) do
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
    case context.type_of.(map) do
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
    with %Type{} = map_type <- map_type(context.type_of.(map)),
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
       do: type_result(context.type_of.(map))

  defp synth_fields(%Call{}, %TypeContext{}), do: :unsupported

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
