defmodule RustQ.Meta.Lower.Enum do
  @moduledoc false

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.{Context, TypeContext}
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Spec

  @spec lower(Call.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(%Call{function: :map, args: [collection, mapper]}, %Context{} = context),
    do: {:ok, lower_map(collection, mapper, context)}

  def lower(%Call{function: :sum, args: [collection]}, %Context{} = context),
    do: {:ok, terminal(collection, :sum, context)}

  def lower(
        %Call{function: :reduce, args: [collection, initial, reducer]},
        %Context{} = context
      ),
      do: {:ok, lower_reduce(collection, initial, reducer, context)}

  def lower(
        %Call{function: operation, args: [collection, mapper]},
        %Context{} = context
      )
      when operation in [:filter, :reject, :flat_map, :each, :any?, :all?],
      do: {:ok, lower_operation(operation, collection, mapper, context)}

  def lower(%Call{function: :count, args: [collection]}, %Context{} = context),
    do: {:ok, collection |> lower_collection(context) |> method_chain(:len) |> cast_i64()}

  def lower(%Call{function: :count, args: [collection, predicate]}, %Context{} = context) do
    iterator = collection |> lower_collection(context) |> method_chain(:into_iter)
    {:ok, iterator |> lower_filter_map(predicate, false, context, :count) |> cast_i64()}
  end

  def lower(%Call{function: :empty?, args: [collection]}, %Context{} = context),
    do:
      {:ok,
       collection
       |> lower_collection(context)
       |> method_chain(:into_iter)
       |> method_chain(:next)
       |> method_chain(:is_none)}

  def lower(%Call{function: :member?, args: [collection, value]}, %Context{} = context),
    do:
      {:ok,
       %AST.MethodCall{
         receiver: lower_collection(collection, context),
         method: :contains,
         args: [%AST.Ref{expr: context.lower.(value)}]
       }}

  def lower(%Call{function: :find, args: [collection, predicate]}, %Context{} = context) do
    iterator = collection |> lower_collection(context) |> method_chain(:into_iter)
    {:ok, lower_filter_map(iterator, predicate, false, context, :find_map)}
  end

  def lower(%Call{function: :find, args: [collection, default, predicate]}, %Context{} = context) do
    iterator = collection |> lower_collection(context) |> method_chain(:into_iter)

    {:ok,
     iterator
     |> lower_filter_map(predicate, false, context, :find_map)
     |> method_chain(:unwrap_or, [context.lower.(default)])}
  end

  def lower(%Call{function: :concat, args: [collections]}, %Context{} = context),
    do:
      {:ok,
       collections
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:flatten)
       |> method_chain(:collect)}

  def lower(%Call{function: :concat, args: [left, right]}, %Context{} = context),
    do:
      {:ok,
       left
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:chain, [context.lower.(right)])
       |> method_chain(:collect)}

  def lower(%Call{function: :zip, args: [left, right]}, %Context{} = context),
    do:
      {:ok,
       left
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:zip, [context.lower.(right)])
       |> method_chain(:collect)}

  def lower(%Call{function: :unzip, args: [collection]}, %Context{} = context),
    do:
      {:ok,
       collection
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:unzip)}

  def lower(%Call{function: :reverse, args: [collection]}, %Context{} = context),
    do:
      {:ok,
       collection
       |> context.lower.()
       |> method_chain(:into_iter)
       |> method_chain(:rev)
       |> method_chain(:collect)}

  def lower(%Call{function: :sort, args: [collection]} = call, %Context{} = context) do
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

  def lower(%Call{function: operation, args: [collection, count]} = call, %Context{} = context)
      when operation in [:take, :drop] do
    case Stdlib.nonnegative_count(count, context) do
      {:ok, lowered_count} ->
        method = if operation == :drop, do: :skip, else: :take

        {:ok,
         collection
         |> context.lower.()
         |> method_chain(:into_iter)
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

  def lower(%Call{}, %Context{}), do: :unsupported

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

    closure =
      if mapped_type do
        context.lower_typed_closure.(args, body, mapped_type)
      else
        context.lower_closure.(args, body)
      end

    collection
    |> lower_collection(context)
    |> method_chain(:into_iter)
    |> method_chain(:map, [closure])
    |> collect(context)
  end

  defp lower_map(collection, {:&, _, [{:/, _, [capture, 1]}]}, context) do
    collection
    |> lower_collection(context)
    |> method_chain(:into_iter)
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

  defp terminal(collection, terminal, context) do
    collection
    |> lower_collection(context)
    |> method_chain(:into_iter)
    |> method_chain(terminal)
  end

  defp lower_reduce(
         collection,
         initial,
         {:fn, _, [{:->, _, [[item, accumulator], body]}]},
         context
       ) do
    closure = context.lower_closure.([accumulator, item], body)

    collection
    |> lower_collection(context)
    |> method_chain(:into_iter)
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
    collection = collection |> lower_collection(context) |> method_chain(:into_iter)

    case operation do
      :filter ->
        lower_filter_map(collection, mapper, false, context)

      :reject ->
        lower_filter_map(collection, mapper, true, context)

      :flat_map ->
        collection |> method_chain(:flat_map, [mapper(mapper, context)]) |> collect(context)

      :each ->
        method_chain(collection, :for_each, [mapper(mapper, context)])

      :any? ->
        method_chain(collection, :any, [mapper(mapper, context)])

      :all? ->
        method_chain(collection, :all, [mapper(mapper, context)])
    end
  end

  defp lower_filter_map(collection, predicate, negate?, context),
    do: lower_filter_map(collection, predicate, negate?, context, :collect)

  defp lower_filter_map(
         collection,
         {:fn, _, [{:->, _, [[argument], body]}]},
         negate?,
         context,
         terminal
       ) do
    name = context.closure_arg.(argument)
    condition = context.lower_closure_body.(body, nil)
    condition = if negate?, do: %AST.UnaryOp{op: :not, expr: condition}, else: condition

    closure = %AST.Closure{
      args: [name],
      body: %AST.If{
        condition: condition,
        then: [%AST.Return{expr: %AST.Some{expr: %AST.Var{name: name}}}],
        else: [%AST.Return{expr: %AST.None{}}]
      }
    }

    if terminal == :find_map do
      method_chain(collection, :find_map, [closure])
    else
      filtered = method_chain(collection, :filter_map, [closure])

      if terminal == :collect,
        do: collect(filtered, context),
        else: method_chain(filtered, terminal)
    end
  end

  defp lower_filter_map(_collection, other, _negate?, _context, _terminal) do
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
