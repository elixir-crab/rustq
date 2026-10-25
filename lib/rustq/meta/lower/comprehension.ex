defmodule RustQ.Meta.Lower.Comprehension do
  @moduledoc """
  Comprehensions, as values and as loops.

  A comprehension used as a value is an iterator pipeline: each generator filters and binds
  its items in one `filter_map`, later generators nest through `flat_map`, and the result is
  collected into the type expected, or the collection `into:` names. Run for its effects, a
  comprehension is nested `for` loops, and `for ..., reduce: acc` is a loop updating `acc`.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Lower.Env, as: Context
  alias RustQ.Meta.Lower.Pattern, as: LowerPattern
  alias RustQ.Meta.Pattern
  alias RustQ.Meta.StdMethods
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust.AST

  @any_vec %AST.TypeVec{inner: %AST.TypeRaw{source: "_"}}
  @iterator_methods StdMethods.iterator()

  @doc "Lowers a comprehension used as a value, collecting into `expected_type` when known."
  # A comprehension with any generators, filters, and refutable patterns, lowered through an
  # iterator pipeline: each generator filters and binds in one `filter_map`, its filters as the
  # match guard; later generators nest through `flat_map`, collecting each inner pipeline so
  # its closures never outlive the outer item they borrow.
  def lower_comprehension(expression, expected_type, %Context{} = context) do
    {qualifiers, opts} = comprehension_parts(expression)

    if Keyword.has_key?(opts, :reduce) do
      Diagnostic.lower(
        :unsupported_for_reduce,
        expression,
        "unsupported defrust for/reduce expression",
        suggestion: "Use `for pattern <- enumerable, reduce: initial do acc_pattern -> body end`."
      )
    end

    body =
      typed_body(
        Keyword.fetch!(opts, :do),
        expected_type && Lower.collection_item_type(expected_type)
      )

    pipeline =
      quote(
        do:
          unquote(comprehension_pipeline(qualifiers, body, context, {false, []}))
          |> collect()
      )

    case expected_type do
      %Type{} = type ->
        lowered = Lower.lower_expr(pipeline, type, context)

        cond do
          Lower.slice_type?(type) -> collect_as(lowered, @any_vec)
          context.position == :statement -> collect_as(lowered, type.ast)
          true -> lowered
        end

      nil ->
        pipeline |> Lower.lower_expr(context) |> collect_as(into_target(opts[:into]))
    end
  end

  # Without an expected type, `into:` names the collection: `HashMap.new()`, `%{}`,
  # `Map.new()`, `HashSet.new()`, or `MapSet.new()`; otherwise a list, as in Elixir.
  defp into_target({:%{}, _, []}), do: inferred_collection(:HashMap, 2)

  defp into_target({{:., _, [{:__aliases__, _, [module]}, :new]}, _, []})
       when module in [:Map, :HashMap, :BTreeMap],
       do: inferred_collection(if(module == :BTreeMap, do: :BTreeMap, else: :HashMap), 2)

  defp into_target({{:., _, [{:__aliases__, _, [module]}, :new]}, _, []})
       when module in [:MapSet, :HashSet, :BTreeSet],
       do: inferred_collection(if(module == :BTreeSet, do: :BTreeSet, else: :HashSet), 1)

  defp into_target(_into), do: @any_vec

  defp inferred_collection(collection, arity) do
    %AST.TypePath{
      parts: [collection],
      generics: List.duplicate(%AST.TypeRaw{source: "_"}, arity)
    }
  end

  @doc "A `collect()` given the type it collects into, when Rust cannot infer it."
  # A comprehension bound in a statement states what it collects into, since Rust may only
  # learn it from a later borrow; without a collection, it makes a list, as in Elixir.
  def collect_as(lowered, nil), do: lowered

  def collect_as(%AST.MethodCall{method: :collect, generics: []} = call, type),
    do: %{call | generics: [type]}

  def collect_as(lowered, _type), do: lowered

  @doc "The type a binding collects into: its own, or a list of what Rust infers for a slice."
  # Without a known type, a binding collects a list, as Elixir's enumerables do.
  def collect_target(%Type{ast: ast} = type),
    do: if(Lower.slice_type?(type), do: @any_vec, else: ast)

  def collect_target(nil), do: @any_vec

  @doc "A comprehension split into its qualifiers and its options, `into:`, `reduce:`, and `do:`."
  def comprehension_parts({:for, _, args}) do
    {opts, qualifiers} = args |> Enum.reverse() |> Enum.split_while(&Keyword.keyword?/1)
    {Enum.reverse(qualifiers), opts |> Enum.reverse() |> Enum.concat()}
  end

  # `nested?` says whether earlier generators enclose this one, and `generated` names the
  # variables they bound.
  defp comprehension_pipeline(
         [{:<-, _, [pattern, collection]} | rest],
         body,
         context,
         {nested?, generated}
       ) do
    {filters, rest} = Enum.split_while(rest, &(not generator?(&1)))
    item_type = comprehension_item_type(collection, context)
    root = root_variable(collection)

    reused? =
      root != nil and
        ((nested? and root not in generated) or
           (item_type != nil and root not in generated and
              Lower.in_use?(collection, context)))

    {stage, binder} = generator_stage(pattern, collection, filters, item_type, reused?)
    bound = LowerPattern.context_with_match_pattern(pattern, item_type, context)

    generated = LowerPattern.binding_pattern_names(pattern) ++ generated

    binder_type = binder_type(binder, bound)

    case rest do
      [] ->
        comprehension_map(stage, binder, binder_type, body)

      # A generator over one value, as `{:some, id} <- [record_id(record)]`, matches that value
      # beside the item instead of iterating a list made for it.
      [{:<-, meta, [value_pattern, [value]]} | later] ->
        paired =
          quote(
            do:
              unquote(stage)
              |> map(fn unquote(typed_arg(binder, binder_type)) ->
                {unquote(binder), unquote(value)}
              end)
          )

        comprehension_pipeline(
          [{:<-, meta, [{binder, value_pattern}, paired]} | later],
          body,
          bound,
          {nested?, generated}
        )

      _ ->
        quote(
          do:
            unquote(stage)
            |> flat_map(fn unquote(typed_arg(binder, binder_type)) ->
              Vec.from_iter(unquote(comprehension_pipeline(rest, body, bound, {true, generated})))
            end)
        )
    end
  end

  defp comprehension_pipeline(qualifiers, _body, _context, _generated) do
    Diagnostic.lower(
      :unsupported_comprehension,
      qualifiers,
      "unsupported defrust comprehension",
      suggestion: "Start the comprehension with a `pattern <- enumerable` generator."
    )
  end

  # A comprehension body lowers as the item type of the collection it builds, when known.
  defp typed_body(body, %Type{} = item_type), do: {:__rustq_typed__, [], [body, item_type]}

  defp typed_body(body, _item_type), do: body

  defp untyped({:__rustq_typed__, _, [body, _type]}), do: body

  defp untyped(body), do: body

  # A generator over a list gives its closures the list's items, which they may then use as
  # that type; other collections leave their items untyped.
  defp comprehension_item_type(collection, %Context{} = context) do
    unless iterator_call?(collection) do
      case Lower.infer_expr_type(collection, context.vars) ||
             Typing.synth(collection, Lower.typing_env(context)) do
        %Type{kind: :vec} = type -> Type.vec_inner(type)
        _unknown -> nil
      end
    end
  end

  # The type of the variables a generator binds, as one variable or a tuple of them.
  defp binder_type({name, _, ast_context}, %Context{vars: vars}) when is_atom(ast_context),
    do: Map.get(vars, name)

  defp binder_type(binder, %Context{} = context) do
    with [_ | _] = elements <- Pattern.tuple_elements(binder),
         types = Enum.map(elements, &binder_type(&1, context)),
         true <- Enum.all?(types, &match?(%Type{}, &1)) do
      Type.tuple(types)
    else
      _unknown -> nil
    end
  end

  defp typed_arg(arg, %Type{} = type), do: {:__rustq_typed_arg__, [], [arg, type]}

  defp typed_arg(arg, nil), do: arg

  # An item the body returns as it is needs no mapping, and one it clones is `cloned()`.
  defp comprehension_map(stage, binder, binder_type, body) do
    plain = untyped(body)

    cond do
      same_variables?(binder, plain) ->
        stage

      match?({{:., _, [_, :clone]}, _, []}, plain) and
          same_variables?(binder, plain |> elem(0) |> elem(2) |> hd()) ->
        quote(do: unquote(stage) |> cloned())

      true ->
        binder = binder |> unused_as_underscored(body) |> typed_arg(binder_type)
        quote(do: unquote(stage) |> map(fn unquote(binder) -> unquote(body) end))
    end
  end

  # A binder variable the body does not use is ignored.
  defp unused_as_underscored(binder, body) do
    {_body, used} =
      Macro.prewalk(body, MapSet.new(), fn
        {name, _, context} = node, used when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(used, name)}

        node, used ->
          {node, used}
      end)

    Macro.prewalk(binder, fn
      {name, meta, context} = node when is_atom(name) and is_atom(context) ->
        if MapSet.member?(used, name), do: node, else: {:_, meta, context}

      node ->
        node
    end)
  end

  defp same_variables?({name, _, context}, {name, _, context}) when is_atom(context), do: true

  defp same_variables?(left, right) do
    case {Pattern.tuple_elements(left), Pattern.tuple_elements(right)} do
      {lefts, rights}
      when is_list(lefts) and is_list(rights) and length(lefts) == length(rights) ->
        lefts |> Enum.zip_with(rights, &same_variables?/2) |> Enum.all?()

      _different ->
        false
    end
  end

  defp generator?({:<-, _, [_pattern, _collection]}), do: true

  defp generator?(_qualifier), do: false

  # A generator that cannot fail and has no filters iterates as it is; otherwise its items are
  # matched, filtered, and reduced to the variables the pattern binds.
  # A later generator over a collection from outside the comprehension iterates it once per
  # item of the earlier ones, so it copies its items rather than consuming it, as does a
  # generator over a collection still in use or reached through a reference.
  defp generator_stage(pattern, collection, filters, item_type, reused?) do
    items =
      cond do
        iterator_call?(collection) -> collection
        reused? -> quote(do: unquote(collection) |> iter() |> cloned())
        true -> quote(do: unquote(collection) |> into_iter())
      end

    if filters == [] and LowerPattern.binding_pattern?(pattern) do
      {items, pattern}
    else
      binder = LowerPattern.pattern_binder(pattern)

      {filter_bind(items, LowerPattern.guarded_pattern(pattern, filters), binder, item_type),
       binder}
    end
  end

  defp root_variable({name, _, ast_context}) when is_atom(name) and is_atom(ast_context), do: name

  # The variable a collection is, or is a field of; a call or literal makes a fresh one.
  defp root_variable({{:., _, [receiver, _field]}, meta, []}),
    do: if(meta[:no_parens], do: root_variable(receiver))

  defp root_variable(_collection), do: nil

  # A collection already given as an iterator, as in `values.iter()`, is iterated as it is.
  defp iterator_call?({{:., _, [_receiver, method]}, _, args}) when is_list(args),
    do: method in @iterator_methods

  defp iterator_call?({:|>, _, [_left, {method, _, args}]}) when is_list(args),
    do: method in @iterator_methods

  defp iterator_call?(_collection), do: false

  defp filter_bind(items, guarded, binder, item_type) do
    item = quote(do: item)

    quote do
      unquote(items)
      |> filter_map(fn unquote(typed_arg(item, item_type)) ->
        case unquote(item) do
          unquote(guarded) -> some(unquote(binder))
          _ -> nil
        end
      end)
    end
  end

  @doc "Lowers a comprehension run for its effects, as nested `for` loops."
  # A comprehension evaluated for its effects: nested loops, `if let` for patterns that can fail,
  # and `if` for filters, so the body may return early.
  def lower_for_loop([{:<-, _, [pattern, collection]} | rest], body, %Context{} = context) do
    body_context = LowerPattern.context_with_for_pattern(pattern, collection, context)

    if LowerPattern.binding_pattern?(pattern) do
      %AST.For{
        pattern: LowerPattern.lower_binding_pattern(pattern),
        expr: Lower.lower_expr(collection, context),
        body: lower_for_loop_body(rest, body, body_context)
      }
    else
      %AST.For{
        pattern: %AST.PatVar{name: :__rustq_item},
        expr: Lower.lower_expr(collection, context),
        body: [
          %AST.IfLet{
            pattern: LowerPattern.lower_match_pattern(pattern, nil, context),
            expr: %AST.Var{name: :__rustq_item},
            then:
              lower_for_loop_body(
                rest,
                body,
                LowerPattern.context_with_match_pattern(pattern, nil, context)
              )
          }
        ]
      }
    end
  end

  defp lower_for_loop_body([], body, %Context{} = context),
    do: Lower.lower_clause_body(body, context)

  defp lower_for_loop_body([{:<-, _, _} | _] = qualifiers, body, %Context{} = context),
    do: [lower_for_loop(qualifiers, body, context)]

  defp lower_for_loop_body([filter | rest], body, %Context{} = context) do
    [
      %AST.ExprStmt{
        expr: %AST.If{
          condition: Lower.lower_expr(filter, context),
          then: lower_for_loop_body(rest, body, context)
        }
      }
    ]
  end

  @doc "Lowers `for ..., reduce: acc` as a loop updating `acc`."
  def lower_for_reduce_expr(expression, %Context{return_type: %Type{} = return_type} = context),
    do: lower_for_reduce_expr(expression, return_type, context)

  def lower_for_reduce_expr(
        {:for, _, [{:<-, _, [pattern, expression]}, [reduce: initial], [do: clauses]]},
        %Type{} = return_type,
        %Context{} = context
      ) do
    acc = :__rustq_reduce
    acc_type = reduce_acc_type(initial, return_type)

    %AST.BlockExpr{
      body: [
        %AST.Let{
          pattern: %AST.PatVar{name: acc},
          mutable: true,
          expr: lower_reduce_initial(initial, acc_type, context)
        },
        %AST.For{
          pattern: LowerPattern.lower_binding_pattern(pattern),
          expr: Lower.lower_expr(expression, context),
          body: [
            %AST.Assign{
              target: %AST.Var{name: acc},
              expr: %AST.Match{
                expr: %AST.Var{name: acc},
                arms: lower_for_reduce_arms(clauses, acc_type, context)
              }
            }
          ]
        },
        %AST.Return{expr: %AST.Var{name: acc}}
      ]
    }
  end

  def lower_for_reduce_expr(other, _return_type, _context) do
    Diagnostic.lower(
      :unsupported_for_reduce,
      other,
      "unsupported defrust for/reduce expression",
      suggestion: "Use `for pattern <- enumerable, reduce: initial do acc_pattern -> body end`."
    )
  end

  defp lower_reduce_initial(initial, %Type{} = acc_type, %Context{} = context) do
    if Type.propagates?(acc_type) do
      Lower.lower_return_expr(initial, acc_type, context)
    else
      Lower.lower_expr(initial, acc_type, context)
    end
  end

  defp reduce_acc_type(:ok, %Type{kind: :nif_result}) do
    unit = %Type{kind: :unit, rust: "()", ast: %AST.TypeUnit{}}

    %Type{
      kind: :nif_result,
      rust: "NifResult<()>",
      ast: %AST.TypeNifResult{inner: unit.ast},
      meta: %{inner: unit}
    }
  end

  defp reduce_acc_type(_initial, %Type{} = return_type), do: return_type

  defp lower_for_reduce_arms(clauses, %Type{} = return_type, %Context{} = context) do
    carry = :__rustq_reduce_value

    Enum.map(clauses, fn {:->, _, [[pattern], body]} ->
      body_context = LowerPattern.context_with_match_pattern(pattern, return_type, context)

      %AST.Arm{
        pattern: LowerPattern.lower_match_pattern(pattern, return_type, context),
        body:
          Lower.lower_clause_body(
            body,
            %{body_context | position: :return, return_type: return_type},
            return_type
          )
      }
    end) ++
      [
        %AST.Arm{
          pattern: %AST.PatVar{name: carry},
          body: [%AST.Return{expr: %AST.Var{name: carry}}]
        }
      ]
  end
end
