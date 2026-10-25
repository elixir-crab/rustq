defmodule RustQ.Meta.Lower.Enum do
  @moduledoc """
  Lowers `Enum` functions over lists as iterator chains: mapping, filtering, reducing,
  searching, sorting, and zipping for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Capture
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Lower.Map, as: MapLowering
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Spec

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{args: args} = call, %Context{} = context),
    do: lower_call(%{call | args: Enum.map(args, &Capture.expand/1)}, context)

  defp lower_call(%Call{function: :map, args: [collection, mapper]}, %Context{} = context),
    do: {:ok, lower_map(collection, mapper, context)}

  defp lower_call(%Call{function: :sum, args: [collection]}, %Context{} = context),
    do: {:ok, collection |> iterate(:question, [], context) |> method_chain(:sum)}

  defp lower_call(
         %Call{function: :reduce, args: [collection, initial, reducer]},
         %Context{} = context
       ),
       do: {:ok, lower_reduce(collection, initial, reducer, context)}

  defp lower_call(
         %Call{function: operation, args: [collection, mapper]},
         %Context{} = context
       )
       when operation in [:filter, :reject, :flat_map, :each, :any?, :all?],
       do: {:ok, lower_operation(operation, collection, mapper, context)}

  defp lower_call(%Call{function: :count, args: [collection]}, %Context{} = context),
    do: {:ok, collection |> lower_collection(context) |> method_chain(:len) |> cast_i64()}

  defp lower_call(%Call{function: :count, args: [collection, predicate]}, %Context{} = context) do
    iterator = iterate(collection, :question, [predicate], context)
    {:ok, iterator |> lower_filter(predicate, false, collection, context, :count) |> cast_i64()}
  end

  defp lower_call(%Call{function: :empty?, args: [collection]}, %Context{} = context),
    do:
      {:ok,
       collection
       |> iterate(:question, [], context)
       |> method_chain(:next)
       |> method_chain(:is_none)}

  defp lower_call(%Call{function: :member?, args: [collection, value]}, %Context{} = context),
    do:
      {:ok,
       %AST.MethodCall{
         receiver: lower_collection(collection, context),
         method: :contains,
         args: [%AST.Ref{expr: context.lower.(value)}]
       }}

  defp lower_call(%Call{function: :find, args: [collection, predicate]}, %Context{} = context) do
    iterator = iterate(collection, :keeps_items, [predicate], context)
    {:ok, lower_filter(iterator, predicate, false, collection, context, :find)}
  end

  defp lower_call(
         %Call{function: :find, args: [collection, default, predicate]},
         %Context{} = context
       ) do
    iterator = iterate(collection, :keeps_items, [default, predicate], context)

    {:ok,
     iterator
     |> lower_filter(predicate, false, collection, context, :find)
     |> method_chain(:unwrap_or, [context.lower.(default)])}
  end

  defp lower_call(%Call{function: :concat, args: [collections]}, %Context{} = context),
    do:
      {:ok,
       collections
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:flatten)
       |> method_chain(:collect)}

  defp lower_call(%Call{function: :concat, args: [left, right]}, %Context{} = context),
    do:
      {:ok,
       left
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:chain, [context.lower.(right)])
       |> method_chain(:collect)}

  defp lower_call(%Call{function: :zip, args: [left, right]}, %Context{} = context),
    do:
      {:ok,
       left
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:zip, [context.lower.(right)])
       |> method_chain(:collect)}

  defp lower_call(%Call{function: :unzip, args: [collection]}, %Context{} = context),
    do:
      {:ok,
       collection
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:unzip)}

  defp lower_call(%Call{function: :reverse, args: [collection]}, %Context{} = context),
    do:
      {:ok,
       collection
       |> iterate(:keeps_items, [], context)
       |> method_chain(:rev)
       |> method_chain(:collect)}

  defp lower_call(%Call{function: :sort, args: [collection]} = call, %Context{} = context) do
    case collection_inner(context.type_of.(collection)) do
      %Type{} = inner
      when inner.kind in [:i8, :i16, :i32, :i64, :isize, :u8, :u16, :u32, :u64, :usize] ->
        name = :rustq_sorted_values
        variable = %AST.Var{name: name}

        {:ok,
         %AST.BlockExpr{
           body: [
             %AST.Let{pattern: %AST.PatVar{name: name}, expr: context.lower.(collection)},
             %AST.ExprStmt{expr: method_chain(variable, :sort)},
             %AST.Return{expr: variable}
           ]
         }}

      _type ->
        Diagnostic.lower(
          :unsupported_enum_sort_semantics,
          call.source,
          "Enum.sort/1 currently requires a statically typed integer collection",
          suggestion: "Use an explicit comparator adapter for other ordering semantics."
        )
    end
  end

  defp lower_call(
         %Call{function: operation, args: [collection, count]} = call,
         %Context{} = context
       )
       when operation in [:take, :drop] do
    case Stdlib.nonnegative_count(count, context) do
      {:ok, lowered_count} ->
        method = if operation == :drop, do: :skip, else: :take

        {:ok,
         collection
         |> iterate(:keeps_items, [count], context)
         |> method_chain(method, [lowered_count])
         |> method_chain(:collect)}

      :unsupported ->
        Diagnostic.lower(
          :unsupported_enum_count_semantics,
          call.source,
          "Enum.#{operation}/2 requires a non-negative literal or unsigned count type",
          suggestion: "Use R.usize() for dynamic non-negative native counts."
        )
    end
  end

  defp lower_call(%Call{function: :into, args: [enumerable, collectable | transform]}, context) do
    case empty_collectable(collectable) do
      nil when transform == [] ->
        {:ok,
         Collection.updated(
           collectable,
           [enumerable],
           fn collection ->
             [
               Collection.statement(collection, :extend, [
                 Collection.owned(enumerable, [], context)
               ])
             ]
           end,
           context
         )}

      nil ->
        :unsupported

      into ->
        {:ok,
         MapLowering.collect(MapLowering.comprehension(enumerable, transform, into), context)}
    end
  end

  # Groups keep their items in order, as Elixir's do.
  defp lower_call(%Call{function: :group_by, args: [enumerable, key | value]}, context) do
    item = Macro.var(:rustq_item, __MODULE__)
    groups = Macro.var(:rustq_groups, __MODULE__)
    value = if value == [], do: item, else: apply_function(hd(value), item)

    block =
      quote do
        unquote(groups) = HashMap.new()

        for unquote(item) <- unquote(enumerable) do
          unquote(groups).entry(unquote(apply_function(key, item))).or_default().push(
            unquote(value)
          )
        end

        unquote(groups)
      end

    {:ok, context.lower_closure_body.(block, context.expected)}
  end

  # An index counts as Rust indexes do, in `usize`.
  defp lower_call(%Call{function: :with_index, args: [enumerable]}, context) do
    {:ok,
     enumerable
     |> iterate(:keeps_items, [], context)
     |> method_chain(:enumerate)
     |> method_chain(:map, [
       %AST.Closure{
         args: [%AST.PatTuple{patterns: [%AST.PatVar{name: :index}, %AST.PatVar{name: :item}]}],
         body: %AST.Tuple{values: [%AST.Var{name: :item}, %AST.Var{name: :index}]}
       }
     ])
     |> collect(context)}
  end

  defp lower_call(%Call{function: :find_index, args: [enumerable, predicate]}, context) do
    iteration = iteration(enumerable, :question, [predicate], context)
    predicate = typed_mapper(predicate, enumerable, iteration, context)

    {:ok,
     enumerable
     |> iterate(iteration, context)
     |> method_chain(:position, [mapper(predicate, context)])}
  end

  # The function gives `some(value)` for the value to find and `nil` to go on.
  defp lower_call(%Call{function: :find_value, args: [enumerable, function]}, context) do
    iteration = iteration(enumerable, :maps_items, [function], context)
    function = typed_mapper(function, enumerable, iteration, context)

    {:ok,
     enumerable
     |> iterate(iteration, context)
     |> method_chain(:find_map, [mapper(function, context)])}
  end

  # `{:cont, acc}` goes on and `{:halt, acc}` stops, as `Ok` and `Err` do for `try_fold`.
  defp lower_call(
         %Call{
           function: :reduce_while,
           args: [
             enumerable,
             initial,
             {:fn, _, [{:->, _, [[item, accumulator], body]}]} = reducer
           ]
         },
         context
       ) do
    iteration = iteration(enumerable, :maps_items, [initial, reducer], context)
    [item] = typed_items([item], enumerable, iteration, context)
    closure = context.lower_closure.([accumulator, item], continuation(body))

    {:ok,
     enumerable
     |> iterate(iteration, context)
     |> method_chain(:try_fold, [context.lower.(initial), closure])
     |> method_chain(:unwrap_or_else, [
       %AST.Closure{args: [:rustq_halted], body: %AST.Var{name: :rustq_halted}}
     ])}
  end

  defp lower_call(%Call{function: :sort_by, args: [enumerable, key | order]}, context) do
    case order do
      [] -> {:ok, sort_by(enumerable, key, :asc, context)}
      [order] when order in [:asc, :desc] -> {:ok, sort_by(enumerable, key, order, context)}
      _comparator -> :unsupported
    end
  end

  # Elixir gives the first greatest item; the least by the reversed key is that one.
  defp lower_call(%Call{function: function, args: [enumerable, key, fallback]}, context)
       when function in [:max_by, :min_by] do
    with {:ok, fallback} <- empty_fallback(fallback, context) do
      order = if function == :max_by, do: :desc, else: :asc

      enumerable
      |> iterate(:keeps_items, [key, fallback], context)
      |> method_chain(:min_by_key, [key_function(enumerable, key, order, context)])
      |> fallback.()
      |> then(&{:ok, &1})
    end
  end

  defp lower_call(%Call{function: function, args: [enumerable, fallback]}, context)
       when function in [:max, :min] do
    with {:ok, fallback} <- empty_fallback(fallback, context) do
      enumerable
      |> iterate(:keeps_items, [fallback], context)
      |> method_chain(function)
      |> fallback.()
      |> then(&{:ok, &1})
    end
  end

  defp lower_call(%Call{function: :uniq, args: [enumerable]}, context),
    do: lower_uniq(enumerable, [], context)

  defp lower_call(%Call{function: :uniq_by, args: [enumerable, key]}, context),
    do: lower_uniq(enumerable, [key], context)

  defp lower_call(%Call{function: :dedup, args: [enumerable]}, context) do
    {:ok,
     Collection.updated(
       enumerable,
       [],
       fn list -> [Collection.statement(list, :dedup, [])] end,
       context
     )}
  end

  defp lower_call(%Call{function: :split_with, args: [enumerable, predicate]}, context) do
    case context.type_of.(enumerable) |> collection_inner() do
      %Type{} = inner ->
        iterator = iterate(enumerable, :keeps_items, [predicate], context)
        partitioned = lower_filter(iterator, predicate, false, enumerable, context, :partition)
        {:ok, %{partitioned | generics: [Type.vec(inner).ast, %AST.TypeRaw{source: "_"}]}}

      nil ->
        :unsupported
    end
  end

  defp lower_call(%Call{function: :at, args: [enumerable, index | default]} = call, context) do
    case Stdlib.nonnegative_count(index, context) do
      {:ok, index} ->
        found =
          context.lower.(enumerable)
          |> method_chain(:get, [index])
          |> Collection.read_out(
            collection_inner(context.type_of.(enumerable)) || %Type{kind: :type}
          )

        case default do
          [] -> {:ok, found}
          [default] -> {:ok, method_chain(found, :unwrap_or, [context.lower.(default)])}
        end

      :unsupported ->
        unsupported_count!(call)
    end
  end

  defp lower_call(%Call{function: :slice, args: [enumerable, start, amount]} = call, context) do
    with {:ok, start} <- Stdlib.nonnegative_count(start, context),
         {:ok, amount} <- Stdlib.nonnegative_count(amount, context) do
      {:ok,
       enumerable
       |> iterate(:keeps_items, [], context)
       |> method_chain(:skip, [start])
       |> method_chain(:take, [amount])
       |> collect(context)}
    else
      :unsupported -> unsupported_count!(call)
    end
  end

  defp lower_call(%Call{function: function, args: [enumerable, predicate]}, context)
       when function in [:take_while, :drop_while] do
    iterator = iterate(enumerable, :keeps_items, [predicate], context)
    {:ok, lower_filter(iterator, predicate, false, enumerable, context, function)}
  end

  defp lower_call(
         %Call{function: :zip_with, args: [left, right, {:fn, _, [{:->, _, [[x, y], body]}]}]},
         context
       ) do
    lefts = iterate(left, :maps_items, [right, body], context)

    # `zip` takes anything iterable, so an owned list goes in as it is.
    rights =
      case iteration(right, :maps_items, [body], context) do
        :owned -> context.lower.(right)
        iteration -> iterate(right, iteration, context)
      end

    {:ok,
     lefts
     |> method_chain(:zip, [rights])
     |> method_chain(:map, [context.lower_closure.([{x, y}], body)])
     |> collect(context)}
  end

  defp lower_call(%Call{function: :chunk_every, args: [enumerable, count]} = call, context) do
    case Stdlib.nonnegative_count(count, context) do
      {:ok, count} ->
        {:ok,
         context.lower.(enumerable)
         |> method_chain(:chunks, [count])
         |> method_chain(:map, [
           %AST.Closure{args: [:chunk], body: method_chain(%AST.Var{name: :chunk}, :to_vec)}
         ])
         |> collect(context)}

      :unsupported ->
        unsupported_count!(call)
    end
  end

  defp lower_call(%Call{function: :join, args: [enumerable | separator]}, context) do
    if strings?(context.type_of.(enumerable)),
      do:
        {:ok,
         method_chain(context.lower.(enumerable), :join, [join_separator(separator, context)])},
      else: :unsupported
  end

  defp lower_call(%Call{function: :map_join, args: [enumerable | rest]}, context) do
    {separator, function} =
      case rest do
        [function] -> {[], function}
        [separator, function] -> {[separator], function}
      end

    iteration = iteration(enumerable, :maps_items, [function], context)
    function = typed_mapper(function, enumerable, iteration, context)

    strings =
      enumerable
      |> iterate(iteration, context)
      |> method_chain(:map, [mapper(function, context)])
      |> then(
        &%AST.MethodCall{
          receiver: &1,
          method: :collect,
          args: [],
          generics: [Type.vec(string_type()).ast]
        }
      )

    {:ok, method_chain(strings, :join, [join_separator(separator, context)])}
  end

  defp lower_call(%Call{}, %Context{}), do: :unsupported

  @spec synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported
  def synth(%Call{function: :sum, args: [collection]}, %TypeContext{} = context),
    do: collection |> context.type_of.() |> collection_inner_result()

  def synth(
        %Call{function: :reduce, args: [_collection, initial, _reducer]},
        %TypeContext{} = context
      ),
      do: type_result(context.type_of.(initial))

  def synth(%Call{function: operation}, %TypeContext{}) when operation in [:any?, :all?],
    do: {:ok, Spec.type(quote(do: boolean()))}

  def synth(%Call{function: :each}, %TypeContext{}),
    do: {:ok, Spec.type(quote(do: RustQ.Type.unit()))}

  def synth(%Call{function: operation, args: [collection, _mapper]}, %TypeContext{} = context)
      when operation in [:filter, :reject] do
    case context.type_of.(collection) do
      %Type{} = type ->
        case Type.vec_inner(type) || Type.slice_inner(type) do
          %Type{} = inner -> {:ok, Type.vec(inner)}
          nil -> :unsupported
        end

      _unknown ->
        :unsupported
    end
  end

  def synth(%Call{function: :map, args: [collection, mapper]}, %TypeContext{} = context) do
    with %Type{} = inner <- collection_inner(context.type_of.(collection)),
         %Type{} = mapped <- mapper_type(mapper, inner, context) do
      {:ok, Type.vec(mapped)}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :flat_map, args: [collection, mapper]}, %TypeContext{} = context) do
    with %Type{} = inner <- collection_inner(context.type_of.(collection)),
         %Type{} = mapped_collection <- mapper_type(mapper, inner, context),
         %Type{} = mapped <- collection_inner(mapped_collection) do
      {:ok, Type.vec(mapped)}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: function}, %TypeContext{})
      when function in [:count, :empty?, :member?],
      do:
        {:ok,
         Spec.type(
           if function == :count,
             do: quote(do: integer()),
             else: quote(do: boolean())
         )}

  def synth(%Call{function: :find, args: [collection, _predicate]}, %TypeContext{} = context) do
    case collection_inner(context.type_of.(collection)) do
      %Type{} = inner -> {:ok, Type.option(inner)}
      nil -> :unsupported
    end
  end

  def synth(
        %Call{function: :find, args: [_collection, default, _predicate]},
        %TypeContext{} = context
      ),
      do: type_result(context.type_of.(default))

  def synth(%Call{function: :concat, args: [collections]}, %TypeContext{} = context) do
    with %Type{} = nested <- collection_inner(context.type_of.(collections)),
         %Type{} = inner <- collection_inner(nested) do
      {:ok, Type.vec(inner)}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :concat, args: [left, _right]}, %TypeContext{} = context),
    do: collection_vec_result(context.type_of.(left))

  def synth(%Call{function: operation, args: [collection | _rest]}, %TypeContext{} = context)
      when operation in [:reverse, :sort, :take, :drop],
      do: collection_vec_result(context.type_of.(collection))

  def synth(%Call{function: :zip, args: [left, right]}, %TypeContext{} = context) do
    with %Type{} = left_inner <- collection_inner(context.type_of.(left)),
         %Type{} = right_inner <- collection_inner(context.type_of.(right)) do
      {:ok, Type.vec(Type.tuple([left_inner, right_inner]))}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :unzip, args: [collection]}, %TypeContext{} = context) do
    with %Type{} = pair <- collection_inner(context.type_of.(collection)),
         %Type{kind: :tuple, meta: %{elements: [left, right]}} <- pair do
      {:ok, Type.tuple([Type.vec(left), Type.vec(right)])}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: function, args: [collection | _]}, %TypeContext{} = context)
      when function in [:sort_by, :uniq, :uniq_by, :dedup, :slice, :take_while, :drop_while],
      do: collection_vec_result(context.type_of.(collection))

  def synth(%Call{function: :with_index, args: [collection]}, %TypeContext{} = context) do
    case collection_inner(context.type_of.(collection)) do
      %Type{} = inner -> {:ok, Type.vec(Type.tuple([inner, usize()]))}
      nil -> :unsupported
    end
  end

  def synth(%Call{function: :find_index}, %TypeContext{}), do: {:ok, Type.option(usize())}

  def synth(%Call{function: :find_value, args: [collection, function]}, %TypeContext{} = context) do
    # It gives an `Option` even when what it finds has no known type.
    found =
      with %Type{} = inner <- collection_inner(context.type_of.(collection)),
           %Type{} = found <- mapper_type(function, inner, context) do
        found
      else
        _unknown -> %Type{kind: :type, rust: "_", ast: %AST.TypeRaw{source: "_"}, meta: %{}}
      end

    {:ok, if(found.kind == :option, do: found, else: Type.option(found))}
  end

  def synth(%Call{function: :reduce_while, args: [_collection, initial, _reducer]}, context),
    do: type_result(context.type_of.(initial))

  def synth(%Call{function: function, args: [collection | rest]}, %TypeContext{} = context)
      when function in [:max_by, :min_by, :max, :min] do
    case {collection_inner(context.type_of.(collection)), List.last(rest)} do
      {nil, _fallback} -> :unsupported
      {inner, {:fn, _, [{:->, _, [[], nil]}]}} -> {:ok, Type.option(inner)}
      {inner, _default} -> {:ok, inner}
    end
  end

  def synth(%Call{function: :split_with, args: [collection, _predicate]}, context) do
    with {:ok, list} <- collection_vec_result(context.type_of.(collection)) do
      {:ok, Type.tuple([list, list])}
    end
  end

  def synth(%Call{function: :at, args: [collection | rest]}, %TypeContext{} = context) do
    case {collection_inner(context.type_of.(collection)), rest} do
      {%Type{} = inner, [_index]} -> {:ok, Type.option(inner)}
      {%Type{} = inner, [_index, _default]} -> {:ok, inner}
      _unknown -> :unsupported
    end
  end

  def synth(%Call{function: :chunk_every, args: [collection, _count]}, context) do
    with {:ok, list} <- collection_vec_result(context.type_of.(collection)) do
      {:ok, Type.vec(list)}
    end
  end

  def synth(%Call{function: function}, %TypeContext{}) when function in [:join, :map_join],
    do: {:ok, string_type()}

  def synth(%Call{function: :group_by, args: [collection, key | value]}, context) do
    with %Type{} = inner <- collection_inner(context.type_of.(collection)),
         %Type{} = key <- mapper_type(key, inner, context),
         %Type{} = value <-
           if(value == [], do: inner, else: mapper_type(hd(value), inner, context)) do
      {:ok, Collection.map(key, Type.vec(value))}
    else
      _unknown -> :unsupported
    end
  end

  def synth(%Call{}, %TypeContext{}), do: :unsupported

  defp lower_map(collection, {:fn, _, [{:->, _, [args, body]}]}, context) do
    mapped_type = collection_inner(context.expected)
    mapper = {:fn, [], [{:->, [], [args, body]}]}
    iteration = iteration(collection, :maps_items, [mapper], context)
    args = typed_items(args, collection, iteration, context)

    closure =
      if mapped_type do
        context.lower_typed_closure.(args, body, mapped_type)
      else
        context.lower_closure.(args, body)
      end

    collection
    |> iterate(iteration, context)
    |> method_chain(:map, [closure])
    |> collect(context)
  end

  defp lower_map(collection, {:&, _, [{:/, _, [capture, 1]}]} = mapper, context) do
    collection
    |> iterate(:maps_items, [mapper], context)
    |> method_chain(:map, [context.lower_capture.(capture)])
    |> collect(context)
  end

  defp lower_map(_collection, other, _context) do
    Diagnostic.lower(
      :unsupported_enum_map_mapper,
      other,
      "unsupported Enum.map mapper in defrust",
      suggestion: "Use an anonymous function mapper, e.g. Enum.map(values, fn value -> ... end)."
    )
  end

  defp lower_reduce(
         collection,
         initial,
         {:fn, _, [{:->, _, [[item, accumulator], body]}]},
         context
       ) do
    reducer = {:fn, [], [{:->, [], [[item, accumulator], body]}]}
    iteration = iteration(collection, :maps_items, [initial, reducer], context)
    [item] = typed_items([item], collection, iteration, context)
    closure = context.lower_closure.([accumulator, item], body)

    collection
    |> iterate(iteration, context)
    |> method_chain(:fold, [context.lower.(initial), closure])
  end

  defp lower_reduce(_collection, _initial, other, _context) do
    Diagnostic.lower(
      :unsupported_enum_reduce_reducer,
      other,
      "unsupported Enum.reduce reducer in defrust",
      suggestion: "Use fn item, accumulator -> ... end as the reducer."
    )
  end

  defp lower_operation(operation, collection, mapper, context) do
    iteration = iteration(collection, operation_use(operation), [mapper], context)

    mapper =
      if operation in [:flat_map, :each, :any?, :all?],
        do: typed_mapper(mapper, collection, iteration, context),
        else: mapper

    iterator = iterate(collection, iteration, context)

    case operation do
      :filter ->
        lower_filter(iterator, mapper, false, collection, context, :collect)

      :reject ->
        lower_filter(iterator, mapper, true, collection, context, :collect)

      :flat_map ->
        iterator |> method_chain(:flat_map, [mapper(mapper, context)]) |> collect(context)

      :each ->
        method_chain(iterator, :for_each, [mapper(mapper, context)])

      :any? ->
        method_chain(iterator, :any, [mapper(mapper, context)])

      :all? ->
        method_chain(iterator, :all, [mapper(mapper, context)])
    end
  end

  defp operation_use(operation) when operation in [:any?, :all?], do: :question
  defp operation_use(operation) when operation in [:filter, :reject], do: :keeps_items
  defp operation_use(_operation), do: :maps_items

  @filter_adapters %{
    find: {:find, nil},
    count: {:filter, :count},
    collect: {:filter, :collect},
    partition: {:partition, :partition},
    take_while: {:take_while, :collect},
    drop_while: {:skip_while, :collect}
  }

  # `filter` and `find` hand their predicate a reference to each item; a number or atom is
  # copied out of it, so the predicate reads the item as its own type.
  defp lower_filter(
         iterator,
         {:fn, _, [{:->, _, [[argument], body]}]},
         negate?,
         collection,
         context,
         terminal
       ) do
    name = context.closure_arg.(argument)
    condition = context.lower_closure_body.(body, nil)
    condition = if negate?, do: %AST.UnaryOp{op: :not, expr: condition}, else: condition

    argument =
      if Collection.copy?(collection_inner(context.type_of.(collection))),
        do: %AST.PatRef{pattern: %AST.PatVar{name: name}},
        else: name

    closure = %AST.Closure{args: [argument], body: condition}

    {method, finish} = Map.fetch!(@filter_adapters, terminal)
    {iterator, kept} = kept_items(iterator, finish)
    adapted = iterator |> method_chain(method, [closure]) |> kept.()

    case finish do
      :collect -> collect(adapted, context)
      :count -> method_chain(adapted, :count)
      _kept -> adapted
    end
  end

  defp lower_filter(_iterator, other, _negate?, _collection, _context, _terminal) do
    Diagnostic.lower(
      :unsupported_enum_filter_predicate,
      other,
      "unsupported Enum filter predicate in defrust",
      suggestion: "Use a one-argument anonymous function predicate."
    )
  end

  # Items copied from a borrowed list are copied once kept, not before they are tested, and
  # not at all when only counted. `partition` keeps every item, so it copies them first.
  defp kept_items(%AST.MethodCall{method: :cloned, receiver: borrowed}, finish)
       when finish != :partition,
       do: {borrowed, if(finish == :count, do: & &1, else: &method_chain(&1, :cloned))}

  defp kept_items(iterator, _finish), do: {iterator, & &1}

  defp mapper({:fn, _, [{:->, _, [args, body]}]}, context),
    do: context.lower_closure.(args, body)

  defp mapper({:&, _, [{:/, _, [capture, 1]}]}, context),
    do: context.lower_capture.(capture)

  defp mapper(other, _context) do
    Diagnostic.lower(
      :unsupported_enum_mapper,
      other,
      "unsupported Enum mapper or predicate in defrust",
      suggestion: "Use an anonymous function or a named one-argument capture."
    )
  end

  defp mapper_type(
         {:fn, _, [{:->, _, [[{name, _, ast_context}], body]}]},
         %Type{} = inner,
         context
       )
       when is_atom(name) and is_atom(ast_context),
       do: context.type_with_vars.(body, %{name => inner})

  defp mapper_type(_mapper, _inner, _context), do: nil

  defp collection_inner(%Type{} = type), do: Type.vec_inner(type) || Type.slice_inner(type)
  defp collection_inner(_type), do: nil

  defp collection_inner_result(%Type{} = type), do: type |> collection_inner() |> type_result()
  defp collection_inner_result(_type), do: :unsupported

  defp collection_vec_result(%Type{} = type) do
    case collection_inner(type) do
      %Type{} = inner -> {:ok, Type.vec(inner)}
      nil -> :unsupported
    end
  end

  defp collection_vec_result(_type), do: :unsupported

  defp type_result(%Type{} = type), do: {:ok, type}
  defp type_result(_type), do: :unsupported

  # A list is iterated by value, so a closure given its items may treat each as the list's
  # element type, as a struct update needs; filters see references and keep untyped arguments.
  defp typed_items([item | rest], collection, iteration, context) do
    case context.type_of.(collection) do
      %Type{kind: :vec} = type ->
        inner = Type.vec_inner(type)
        inner = if iteration == :borrowed, do: Type.ref(inner), else: inner
        [{:__rustq_typed_arg__, [], [item, inner]} | rest]

      _unknown ->
        [item | rest]
    end
  end

  defp typed_items([], _collection, _iteration, _context), do: []

  defp typed_mapper(
         {:fn, meta, [{:->, arrow_meta, [args, body]}]},
         collection,
         iteration,
         context
       ),
       do:
         {:fn, meta,
          [{:->, arrow_meta, [typed_items(args, collection, iteration, context), body]}]}

  defp typed_mapper(mapper, _collection, _iteration, _context), do: mapper

  # Elixir never changes a list, so an operation takes an owned list only where nothing uses it
  # afterwards. A question about a list borrows it; so does any other operation on a list still
  # in use, copying the items it keeps.
  defp iterate(collection, use, others, context),
    do: iterate(collection, iteration(collection, use, others, context), context)

  defp iterate(collection, iteration, context) do
    receiver = lower_collection(collection, context)

    case iteration do
      :owned ->
        if borrowed_collection?(context.type_of.(collection)),
          do: method_chain(receiver, :iter),
          else: method_chain(receiver, :into_iter)

      :borrowed ->
        method_chain(receiver, :iter)

      :copied ->
        receiver |> method_chain(:iter) |> method_chain(:copied)

      :cloned ->
        receiver |> method_chain(:iter) |> method_chain(:cloned)
    end
  end

  # A question needs no item it could take, so it borrows other items even from a list nothing
  # uses afterwards. Copying out a number or atom costs what borrowing it does, and keeps the
  # item's own type.
  defp iteration(collection, use, others, context),
    do: iteration(context.type_of.(collection), collection, use, others, context)

  defp iteration(%Type{kind: :vec} = type, collection, use, others, context),
    do: list_iteration(collection, type, use, others, context)

  defp iteration(%Type{} = type, _collection, :keeps_items, _others, _context),
    do: lent_iteration(type)

  defp iteration(_type, _collection, _use, _others, _context), do: :owned

  defp list_iteration(collection, type, use, others, context) do
    copy? = Collection.copy?(Type.vec_inner(type))
    in_use? = (use == :question and not copy?) or context.in_use?.(collection, others)

    cond do
      not in_use? -> :owned
      copy? -> :copied
      use == :keeps_items -> :cloned
      true -> :borrowed
    end
  end

  # A slice lends its items, so items kept from it are copies.
  defp lent_iteration(type) do
    case Type.slice_inner(type) || collection_inner(type) do
      %Type{} = inner -> if Collection.copy?(inner), do: :copied, else: :cloned
      nil -> :owned
    end
  end

  # A slice or a reference to a collection already lends its items, as `iter()` says.
  defp borrowed_collection?(%Type{kind: kind}) when kind in [:slice, :ref], do: true
  defp borrowed_collection?(%Type{ast: %AST.TypeRef{}}), do: true
  defp borrowed_collection?(_type), do: false

  defp lower_collection(collection, context) do
    case context.type_of.(collection) do
      %Type{kind: :vec} = type -> context.lower_expected.(collection, type)
      _unknown -> context.lower.(collection)
    end
  end

  defp collect(receiver, %Context{expected: %Type{kind: :vec, ast: type}}) do
    %AST.MethodCall{receiver: receiver, method: :collect, args: [], generics: [type]}
  end

  defp collect(receiver, %Context{}), do: method_chain(receiver, :collect)

  defp cast_i64(expression),
    do: %AST.Cast{expr: expression, type: %AST.TypePath{parts: [:i64]}}

  # Keeps each item whose key is new, in order, as Elixir does.
  defp lower_uniq(enumerable, key, context) do
    item = Macro.var(:rustq_item, __MODULE__)
    seen = Macro.var(:rustq_seen, __MODULE__)

    seen_key =
      case key do
        [] ->
          if Collection.copy?(collection_inner(context.type_of.(enumerable))),
            do: item,
            else: quote(do: unquote(item).clone())

        [key] ->
          apply_function(key, item)
      end

    block =
      quote do
        unquote(seen) = HashSet.new()

        Enum.filter(unquote(enumerable), fn unquote(item) ->
          unquote(seen).insert(unquote(seen_key))
        end)
      end

    {:ok, context.lower_closure_body.(block, context.expected || context.type_of.(enumerable))}
  end

  # The comprehension target an empty collectable names, or nil for one with items.
  defp empty_collectable({:%{}, _, []}), do: quote(do: HashMap.new())
  defp empty_collectable([]), do: quote(do: Vec.new())

  defp empty_collectable({{:., _, [{:__aliases__, _, [module]}, :new]}, _, []} = constructor)
       when module in [:Map, :MapSet, :HashMap, :HashSet, :BTreeMap, :BTreeSet],
       do: constructor

  defp empty_collectable(_collectable), do: nil

  # A one-argument function applied to `value`, inlined.
  defp apply_function({:fn, _, [{:->, _, [[{name, _, ast_context}], body]}]}, value)
       when is_atom(name) and is_atom(ast_context) do
    Macro.prewalk(body, fn
      {^name, _, ^ast_context} -> value
      node -> node
    end)
  end

  defp apply_function({:fn, _, [{:->, _, [[pattern], body]}]}, value),
    do: quote(do: case(unquote(value), do: (unquote(pattern) -> unquote(body))))

  defp apply_function({:&, _, [{:/, _, [{{:., _, _} = remote, _, _}, 1]}]}, value),
    do: {remote, [], [value]}

  defp apply_function({:&, _, [{:/, _, [{name, _, _}, 1]}]}, value) when is_atom(name),
    do: {name, [], [value]}

  defp apply_function(other, _value) do
    Diagnostic.lower(
      :unsupported_enum_function,
      other,
      "unsupported Enum function argument in defrust",
      suggestion: "Use a one-argument anonymous function or a named one-argument capture."
    )
  end

  defp continuation(body) do
    Macro.prewalk(body, fn
      {:cont, value} -> quote(do: ok(unquote(value)))
      {:halt, value} -> quote(do: err(unquote(value)))
      node -> node
    end)
  end

  defp sort_by(enumerable, key, order, context) do
    Collection.updated(
      enumerable,
      [key],
      fn list ->
        [
          Collection.statement(list, :sort_by_key, [key_function(enumerable, key, order, context)])
        ]
      end,
      context
    )
  end

  # The key each item sorts by, reversed for `:desc`. A key is a value, as in Elixir, so one
  # read out of an item is cloned rather than borrowed.
  defp key_function(enumerable, key, order, context) do
    item = Macro.var(:rustq_item, __MODULE__)

    arg =
      case collection_inner(context.type_of.(enumerable)) do
        %Type{} = inner -> {:__rustq_typed_arg__, [], [item, Type.ref(inner)]}
        nil -> item
      end

    %AST.Closure{body: body} = closure = context.lower_closure.([arg], apply_function(key, item))

    if order == :desc,
      do: %{
        closure
        | body: %AST.PathCall{path: %AST.Path{parts: [:std, :cmp, :Reverse]}, args: [body]}
      },
      else: closure
  end

  # `fn -> nil end` gives an `Option`; another fallback gives its value for an empty list.
  defp empty_fallback({:fn, _, [{:->, _, [[], nil]}]}, _context), do: {:ok, & &1}

  # A literal or variable costs nothing to compute, so it needs no closure.
  defp empty_fallback({:fn, _, [{:->, _, [[], default]}]}, context) do
    if Macro.quoted_literal?(default) or
         match?({name, _, ctx} when is_atom(name) and is_atom(ctx), default) do
      {:ok, &method_chain(&1, :unwrap_or, [context.lower.(default)])}
    else
      {:ok,
       &method_chain(&1, :unwrap_or_else, [%AST.Closure{args: [], body: context.lower.(default)}])}
    end
  end

  defp empty_fallback(_fallback, _context), do: :unsupported

  defp strings?(%Type{} = type) do
    case collection_inner(type) do
      %Type{} = inner ->
        Type.category(Type.ref_inner(inner) || inner) == :string or inner.rust in ["&str", "str"]

      nil ->
        false
    end
  end

  defp strings?(_type), do: false

  defp string_type, do: RustQ.Spec.type(quote(do: String.t()))
  defp usize, do: RustQ.Spec.type(quote(do: RustQ.Type.usize()))

  defp join_separator([], _context), do: %AST.Literal{value: ""}
  defp join_separator([separator], context), do: context.lower.(separator)

  @spec unsupported_count!(Call.t()) :: no_return()
  defp unsupported_count!(%Call{function: function, source: source}) do
    Diagnostic.lower(
      :unsupported_enum_count_semantics,
      source,
      "Enum.#{function} requires a non-negative literal or unsigned index type",
      suggestion: "Use R.usize() for dynamic non-negative native indexes."
    )
  end

  defp method_chain(receiver, method, args \\ []) do
    %AST.MethodCall{receiver: receiver, method: method, args: args}
  end
end
