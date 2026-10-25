defmodule RustQ.Meta.Lower.Enum do
  @moduledoc """
  Lowers `Enum` functions over lists as iterator chains: mapping, filtering, reducing,
  searching, sorting, and zipping for `RustQ.Meta.Lower.Stdlib`, and types such calls.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Capture
  alias RustQ.Meta.Core.Call
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
      if copy?(collection_inner(context.type_of.(collection))),
        do: %AST.PatRef{pattern: %AST.PatVar{name: name}},
        else: name

    closure = %AST.Closure{args: [argument], body: condition}

    case terminal do
      :find -> method_chain(iterator, :find, [closure])
      :count -> iterator |> method_chain(:filter, [closure]) |> method_chain(:count)
      :collect -> iterator |> method_chain(:filter, [closure]) |> collect(context)
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
  defp iteration(collection, use, others, context) do
    case context.type_of.(collection) do
      %Type{kind: :vec} = type ->
        copy? = copy?(Type.vec_inner(type))
        in_use? = (use == :question and not copy?) or context.in_use?.(collection, others)

        cond do
          not in_use? -> :owned
          copy? -> :copied
          use == :keeps_items -> :cloned
          true -> :borrowed
        end

      _not_owned ->
        :owned
    end
  end

  # A slice or a reference to a collection already lends its items, as `iter()` says.
  defp borrowed_collection?(%Type{kind: kind}) when kind in [:slice, :ref], do: true
  defp borrowed_collection?(%Type{ast: %AST.TypeRef{}}), do: true
  defp borrowed_collection?(_type), do: false

  defp copy?(%Type{} = type), do: Type.category(type) in [:integer, :number, :boolean, :atom]
  defp copy?(_type), do: false

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

  defp method_chain(receiver, method, args \\ []) do
    %AST.MethodCall{receiver: receiver, method: method, args: args}
  end
end
