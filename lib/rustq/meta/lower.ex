defmodule RustQ.Meta.Lower do
  @moduledoc """
  Lowers Rusty-Elixir to RustQ AST: expressions, statements, control flow, calls, and closures,
  with the borrows, `?` propagation, and wrapping their expected types call for.

  A body is first desugared by `RustQ.Meta.Desugar` and annotated by `RustQ.Meta.Ownership`.
  Lowering then hands parts to the modules beside it, which call back into `lower_expr/2`:

    * `RustQ.Meta.Lower.Pattern` lowers patterns and binds their variables;
    * `RustQ.Meta.Lower.Comprehension` lowers comprehensions and `for` loops;
    * `RustQ.Meta.Lower.Paths` resolves aliases to Rust paths and calls to callables;
    * `RustQ.Meta.Lower.Mutability` marks what lowered Rust changes `mut`;
    * `RustQ.Meta.Lower.Stdlib` lowers calls into Elixir's standard library.
  """

  alias RustQ.Binding.Index, as: BindingIndex
  alias RustQ.Diagnostic
  alias RustQ.Meta.Capture
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Desugar
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Lower.Comprehension
  alias RustQ.Meta.Lower.Mutability
  alias RustQ.Meta.Lower.Paths
  alias RustQ.Meta.Lower.Pattern, as: LowerPattern
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.Lowering.Context, as: StdlibContext
  alias RustQ.Meta.Ownership
  alias RustQ.Meta.RustMacro
  alias RustQ.Meta.Semantics
  alias RustQ.Meta.StdMethods
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.Identifier

  # A vector whose item type Rust infers, for collecting where none is known.
  @any_vec %AST.TypeVec{inner: %AST.TypeRaw{source: "_"}}

  defmodule Env do
    @moduledoc """
    What lowering knows at a point in a body. `scope_return_type` is what the enclosing
    function or closure returns, which `?` exits into; `return_type` is what the block being
    lowered must produce. `captured` names the variables enclosing closures capture, which a
    closure called once per item must not move.
    """
    defstruct [
      :return_type,
      :scope_return_type,
      vars: %{},
      captured: MapSet.new(),
      lexical_vars: %{},
      type_aliases: %{},
      position: :return,
      rust_modules: %{},
      callables: %BindingIndex{},
      macro_vars: %{},
      rust_macros: %{},
      built_from: %{}
    ]

    @type t :: %__MODULE__{}
  end

  alias __MODULE__.Env, as: Context

  @spec quoted_body(Macro.t(), Type.t() | nil, map(), keyword()) :: [struct()]
  def quoted_body(body_ast, return_type, vars \\ %{}, opts \\ []) do
    {body_ast, built_from} = body_ast |> Desugar.desugar() |> Ownership.annotate()

    context = %Context{
      built_from: built_from,
      return_type: return_type,
      scope_return_type: return_type,
      type_aliases: Keyword.get(opts, :type_aliases, %{}),
      vars: vars,
      rust_modules: Keyword.get(opts, :rust_modules, %{}),
      callables: BindingIndex.new(Keyword.get(opts, :callables)),
      macro_vars: Keyword.get(opts, :macro_vars, %{}),
      rust_macros: Keyword.get(opts, :rust_macros, %{})
    }

    body_ast
    |> block_expressions()
    |> lower_block(context)
    |> Mutability.infer_mutability()
  end

  @spec function_body(Macro.t(), Type.t(), map(), keyword()) :: String.t()
  def function_body(body_ast, return_type, vars \\ %{}, opts \\ []) do
    body_ast
    |> quoted_body(return_type, vars, opts)
    |> Enum.map_join("\n", &Rust.render/1)
  end

  defp lower_block(expressions, %Context{} = context) do
    context = context_with_downstream_let_types(expressions, context)

    {statements, final} = split_final(expressions)
    statement_context = %{context | position: :statement}
    return_context = %{context | position: :return}

    Enum.map(statements, &lower_statement(&1, statement_context)) ++
      [lower_final(final, statement_context, return_context)]
  end

  # A body returning nothing runs its last expression for its effects, as a statement.
  defp lower_final(final, statement_context, %Context{return_type: %Type{kind: :unit}})
       when final not in [:ok, nil],
       do: lower_statement(final, statement_context)

  defp lower_final(final, _statement_context, return_context),
    do: lower_return(final, return_context)

  defp lower_expected_block(expressions, %Context{} = context, %Type{} = expected_type) do
    context = context_with_downstream_let_types(expressions, context)

    {statements, final} = split_final(expressions)
    statement_context = %{context | position: :statement}
    return_context = %{context | position: :return}

    Enum.map(statements, &lower_statement(&1, statement_context)) ++
      [A.return_stmt(lower_expr(final, expected_type, return_context))]
  end

  @keyed_collections [:HashMap, :HashSet, :BTreeMap, :BTreeSet]
  @stdlib_modules [:Kernel, :Enum, :List, :Map, :MapSet, :String, :Tuple, :Range]
  @iterator_option_methods StdMethods.iterator_option()
  @wrapper_methods StdMethods.wrapper()

  # An empty map or set filled through `entry(key).or_default()` leaves Rust without its value
  # type; when RustQ knows it, the binding states it.
  defp empty_collection_type(
         {{:., _, [{:__aliases__, _, [collection]}, constructor]}, _, _args},
         %Type{ast: ast}
       )
       when collection in @keyed_collections and constructor in [:new, :with_capacity, :default],
       do: ast

  defp empty_collection_type(_expression, _expected_type), do: nil

  defp split_final([]), do: {[], :ok}
  defp split_final(expressions), do: {Enum.drop(expressions, -1), List.last(expressions)}

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp lower_statement({:assign!, _, [target, expression]}, %Context{} = context) do
    expected_type = Typing.synth(target, typing_env(context))
    lower_assignment(target, expression, expected_type, context)
  end

  defp lower_statement({:return!, _, [expression]}, %Context{return_type: return_type} = context) do
    %AST.EarlyReturn{expr: lower_return_expr(expression, return_type, context)}
  end

  defp lower_statement({:=, _, [pattern, expression]}, %Context{} = context) do
    expected_type = infer_let_expected_type(pattern, expression, context)
    expression_context = LowerPattern.context_with_lexical_pattern_vars(pattern, context)

    %AST.Let{
      pattern: LowerPattern.lower_binding_pattern(pattern),
      expr:
        expression
        |> lower_expr(expected_type, expression_context)
        |> Comprehension.collect_as(Comprehension.collect_target(expected_type))
        |> lent_item(expression, context),
      type: empty_collection_type(expression, expected_type)
    }
    |> Mutability.updated_in_place()
  end

  defp lower_statement({:case, _, [expression, [do: clauses]]}, %Context{} = context) do
    case lower_option_if_let_statement(expression, normalize_case_clauses(clauses), context) do
      %AST.IfLet{} = if_let -> if_let
      nil -> A.stmt(lower_case(expression, clauses, context))
    end
  end

  defp lower_statement({:if, _, [condition, branches]}, %Context{} = context) do
    A.stmt(lower_if(condition, branches, context))
  end

  # Run for its effects, a `cond` is a chain of `if`s; a final branch doing nothing is left out.
  defp lower_statement({:cond, _, [[do: clauses]]}, %Context{} = context),
    do: lower_statement(cond_statement(clauses), context)

  defp lower_statement({:with, _, clauses} = with, %Context{} = context) do
    case with_if_lets(clauses) do
      {:ok, matches, body} -> lower_statement(nested_if_lets(matches, body), context)
      :error -> A.stmt(lower_with(with |> elem(2), context))
    end
  end

  defp lower_statement(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Context{} = context
       ) do
    A.stmt(lower_statement_expr(expression, context))
  end

  defp lower_statement({:for, _, args} = expression, %Context{} = context) when is_list(args) do
    case Comprehension.comprehension_parts(expression) do
      {qualifiers, [do: body]} ->
        Comprehension.lower_for_loop(qualifiers, body, context)

      _other ->
        A.stmt(Comprehension.lower_comprehension(expression, nil, context))
    end
  end

  defp lower_statement(:ok, %Context{}), do: A.stmt(A.tuple([]))

  defp lower_statement({:__block__, _, [expression]}, context),
    do: lower_statement(expression, context)

  defp lower_statement(nil, %Context{}), do: A.stmt(A.tuple([]))

  defp lower_statement(expression, %Context{} = context) do
    A.stmt(lower_statement_expr(expression, context))
  end

  # An item cannot be moved out of the collection it is indexed in, so one that cannot be copied
  # is borrowed.
  defp lent_item(%AST.Index{} = expr, expression, %Context{} = context) do
    case Typing.synth(expression, typing_env(context)) do
      %Type{} = type -> if Collection.copy?(type), do: expr, else: A.ref(expr)
      nil -> expr
    end
  end

  defp lent_item(expr, _expression, _context), do: expr

  defp cond_statement([{:->, _, [[true], body]} | _rest]), do: body

  defp cond_statement([{:->, meta, [[condition], body]} | rest]) do
    case cond_statement(rest) do
      nothing when nothing in [:ok, nil] -> {:if, meta, [condition, [do: body]]}
      other -> {:if, meta, [condition, [do: body, else: other]]}
    end
  end

  defp cond_statement([]), do: nil

  # A `with` run for its effects whose `else` does nothing is a chain of `if let`s.
  defp with_if_lets(clauses) do
    {matches, [options]} = Enum.split(clauses, -1)

    case options do
      [do: body] ->
        {:ok, matches, body}

      [do: body, else: [{:->, _, [[{:_, _, _}], fallback]}]] when fallback in [:ok, nil] ->
        {:ok, matches, body}

      _ ->
        :error
    end
  end

  defp nested_if_lets([], body), do: body

  defp nested_if_lets([{:<-, meta, [true, condition]} | rest], body),
    do: {:if, meta, [condition, [do: nested_if_lets(rest, body)]]}

  defp nested_if_lets([{:<-, meta, [pattern, expression]} | rest], body),
    do:
      {:case, meta,
       [
         expression,
         [
           do: [
             {:->, meta, [[pattern], nested_if_lets(rest, body)]},
             {:->, meta, [[{:_, meta, nil}], :ok]}
           ]
         ]
       ]}

  defp nested_if_lets([expression | rest], body),
    do: {:__block__, [], [expression, nested_if_lets(rest, body)]}

  defp lower_return({:case, _, [expression, [do: clauses]]}, %Context{} = context) do
    A.return_stmt(lower_case(expression, clauses, context, context.return_type))
  end

  defp lower_return({:if, _, [condition, branches]}, %Context{} = context) do
    A.return_stmt(lower_if(condition, branches, context))
  end

  defp lower_return({:cond, _, [[do: clauses]]}, %Context{} = context) do
    A.return_stmt(lower_cond(clauses, context, context.return_type))
  end

  defp lower_return({:with, _, clauses}, %Context{} = context) do
    A.return_stmt(lower_with(clauses, context))
  end

  defp lower_return(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Context{} = context
       ) do
    A.return_stmt(Comprehension.lower_for_reduce_expr(expression, context))
  end

  defp lower_return(expression, %Context{return_type: return_type} = context),
    do: A.return_stmt(lower_return_expr(expression, return_type, context))

  @doc "Lowers an expression in return position."
  def lower_return_expr(expression, return_type, %Context{} = context),
    do: lower_return_expr_context(expression, return_type, context)

  defp lower_return_expr_context(:ok, %Type{kind: kind} = return_type, %Context{} = context)
       when kind in [:result, :nif_result] do
    if unit_result?(return_type),
      do: %AST.Ok{},
      else: lower_result_return(:ok, return_type, context)
  end

  # `:ok` where nothing is returned is the unit value; where an atom is, it is that atom.
  defp lower_return_expr_context(:ok, %Type{kind: :atom} = return_type, %Context{} = context),
    do: lower_expr(:ok, return_type, context)

  defp lower_return_expr_context(:ok, _return_type, %Context{}), do: A.tuple([])

  # A tail `decode_as!` in a NIF returning what it decodes already is the `NifResult`.
  defp lower_return_expr_context(
         {:decode_as!, _, [expression, type_ast]} = call,
         %Type{kind: :nif_result} = return_type,
         %Context{} = context
       ) do
    if same_rust_type?(Typing.synth(call, typing_env(context)), Type.inner(return_type)),
      do: decode_as_expr(expression, type_ast, context),
      else: lower_result_return(call, return_type, context)
  end

  defp lower_return_expr_context(nil, %Type{kind: :option}, %Context{}), do: %AST.None{}

  defp lower_return_expr_context(
         {:none, _, []},
         %Type{kind: :option},
         %Context{}
       ),
       do: %AST.None{}

  defp lower_return_expr_context(
         {:some, _, [expression]},
         %Type{kind: :option} = return_type,
         %Context{} = context
       ) do
    A.some(lower_expr(expression, Type.inner(return_type), context))
  end

  defp lower_return_expr_context(
         {:ok, value},
         %Type{kind: kind} = return_type,
         %Context{} = context
       )
       when kind in [:result, :nif_result],
       do: A.ok(lower_expr(value, Type.inner(return_type) || return_type, context))

  defp lower_return_expr_context({:error, value}, %Type{kind: :nif_result}, %Context{} = context),
    do: A.err(lower_nif_error(value, context))

  defp lower_return_expr_context(
         {:error, value},
         %Type{kind: :result} = return_type,
         %Context{} = context
       ),
       do: A.err(lower_expr(value, Type.error(return_type), context))

  defp lower_return_expr_context(
         expression,
         %Type{kind: :option} = return_type,
         %Context{} = context
       ) do
    case typing_check(expression, return_type, context) do
      %Typing.Check{coercion: coercion} = check when coercion != :unknown ->
        lower_checked_coercion(check, expression, context)

      %Typing.Check{} ->
        if option_chain?(expression, context),
          do: lower_expr(expression, return_type, context),
          else: A.some(lower_expr(expression, context))
    end
  end

  defp lower_return_expr_context(
         expression,
         %Type{kind: kind} = return_type,
         %Context{} = context
       )
       when kind in [:result, :nif_result],
       do: lower_result_return(expression, return_type, context)

  defp lower_return_expr_context(expression, %Type{} = return_type, %Context{} = context) do
    if infer_propagation?(expression, return_type, context) do
      A.try(lower_expr(expression, context))
    else
      lower_expr(expression, return_type, context)
    end
  end

  defp lower_return_expr_context(expression, _return_type, %Context{} = context),
    do: lower_expr(expression, context)

  # A NIF returning `t` in Elixir is `NifResult<T>` in Rust, so a plain value it returns is
  # `Ok(value)`. A `Result` is Elixir's `{:ok, value} | {:error, reason}`, which a plain value
  # is not. Branching expressions lower each branch as a return, and values of unknown type
  # are left as they are.
  defp lower_result_return(expression, return_type, %Context{} = context) do
    cond do
      infer_propagation?(expression, return_type, context) ->
        A.try(lower_expr(expression, context))

      plain_value?(expression, context) ->
        lower_plain_result(expression, return_type, context)

      true ->
        expression |> lower_expr(return_type, context) |> wrap_atom_result(return_type)
    end
  end

  # An atom from the module's atom registry, as `Atoms.args()` reaches, is a plain value even
  # where typing knows nothing of the call.
  defp wrap_atom_result(
         %AST.PathCall{path: %AST.Path{parts: [:atoms, _name]}, args: []} = atom,
         %Type{kind: :nif_result}
       ),
       do: A.ok(atom)

  defp wrap_atom_result(%AST.AtomValue{} = atom, %Type{kind: :nif_result}),
    do: A.ok(atom)

  defp wrap_atom_result(lowered, _return_type), do: lowered

  defp plain_value?({form, _, _}, _context)
       when form in [:if, :unless, :case, :cond, :with, :__block__, :for],
       do: false

  defp plain_value?(atom, _context) when is_atom(atom) and atom not in [nil, true, false],
    do: true

  defp plain_value?(expression, %Context{} = context) do
    case Typing.synth(expression, typing_env(context)) do
      %Type{kind: kind} when kind in [:result, :nif_result, :option, :unit] -> false
      %Type{} -> true
      _unknown -> false
    end
  end

  # Items collected build the result themselves when they are results, as `Enum.map` over
  # fallible decodes does.
  defp lower_plain_result(expression, return_type, %Context{} = context) do
    case lower_expr(expression, return_type, context) do
      %AST.MethodCall{method: :collect} = collected ->
        collected

      _lowered when return_type.kind == :nif_result ->
        A.ok(lower_expr(expression, Type.inner(return_type), context))

      _lowered ->
        plain_result_value(expression, return_type)
    end
  end

  @spec plain_result_value(Macro.t(), Type.t()) :: no_return()
  defp plain_result_value(expression, return_type) do
    Diagnostic.lower(
      :plain_result_value,
      expression,
      "a function returning #{return_type.rust} returns a plain value",
      suggestion: "Return `{:ok, value}` or `{:error, reason}`."
    )
  end

  # A result carrying nothing, whether its type was parsed from a spec or given as Rust AST.
  defp unit_result?(%Type{rust: rust} = type),
    do:
      match?(%Type{kind: :unit}, Type.inner(type)) or rust == "NifResult<()>" or
        (is_binary(rust) and String.starts_with?(rust, "Result<(), "))

  defp same_rust_type?(%Type{rust: rust}, %Type{rust: rust}), do: true
  defp same_rust_type?(_left, _right), do: false

  # An option a closure maps or chains, or items collected, already is the option returned.
  defp option_chain?({:|>, _, [left, {method, meta, args}]}, context) when is_list(args),
    do: option_chain?({{:., meta, [left, method]}, meta, args}, context)

  defp option_chain?({{:., _, [_receiver, :collect]}, _, []}, _context), do: true

  # Methods that return an option on whatever they are called, as iterators' `next` does.
  defp option_chain?({{:., _, [_receiver, method]}, _, args}, _context)
       when method in @iterator_option_methods and is_list(args),
       do: true

  defp option_chain?({{:., _, [receiver, method]}, _, [_argument]}, context)
       when method in [:map, :and_then, :or, :or_else, :filter] do
    match?(
      %Type{kind: :option},
      infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))
    )
  end

  defp option_chain?(_expression, _context), do: false

  @doc "Lowers an expression, as the `RustQ.Meta.Lower.*` modules lowering its parts call back."
  def lower_expr(expression, %Context{} = context), do: lower_expr_context(expression, context)

  def lower_expr(expression, expected_type, %Context{} = context),
    do: lower_expected_expr_context(expression, declared_type(expected_type, context), context)

  # A type a recursive declaration names inside itself, resolved to the whole declaration.
  defp declared_type(%Type{meta: %{recursive: name}} = type, %Context{type_aliases: aliases}),
    do: Map.get(aliases, {name, 0}, type)

  defp declared_type(type, %Context{}), do: type

  defp declared_case_type(%Type{kind: kind, meta: %{inner: %Type{} = inner}} = type, context)
       when kind in [:ref, :mut_ref] do
    case declared_type(inner, context) do
      ^inner -> type
      declared -> %{type | meta: Map.put(type.meta, :inner, declared)}
    end
  end

  defp declared_case_type(type, context), do: declared_type(type, context)

  defp lower_expected_expr_context(
         {:__block__, _, [expression]},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_expected_expr_context(expression, expected_type, context)

  defp lower_expected_expr_context(
         {:__block__, _, [_first, _second | _rest] = expressions},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: A.block_expr(lower_expected_block(expressions, context, expected_type))

  defp lower_expected_expr_context(
         {tag, _value} = expression,
         %Type{kind: kind} = expected_type,
         %Context{} = context
       )
       when tag in [:ok, :error] and kind in [:result, :nif_result] do
    lower_return_expr(expression, expected_type, context)
  end

  # `{:some, value}` and `:none` where an option is expected are the option, as patterns read
  # them and as `{:ok, value}` is a result.
  defp lower_expected_expr_context({:some, value}, %Type{kind: :option} = expected_type, context),
    do: A.some(lower_expr(value, Type.inner(expected_type), context))

  defp lower_expected_expr_context(:none, %Type{kind: :option}, %Context{}), do: %AST.None{}

  defp lower_expected_expr_context(
         value,
         %Type{meta: %{elixir_module: String, elixir_type: :t}},
         %Context{}
       )
       when is_binary(value),
       do: A.method(A.lit(value), :to_string)

  # A borrowed list literal is a borrowed array, which coerces to the slice expected.
  defp lower_expected_expr_context({:ref, _, [values]}, %Type{} = expected_type, context)
       when is_list(values) do
    item_type = Type.slice_inner(Type.expected_value(expected_type))

    A.ref(%AST.ArrayLiteral{
      values:
        Enum.map(values, fn value ->
          if item_type,
            do: lower_expr(value, item_type, context),
            else: lower_expr(value, context)
        end)
    })
  end

  defp lower_expected_expr_context(
         {:ref, _, [expression]},
         %Type{} = expected_type,
         %Context{} = context
       ) do
    expected_inner = Type.ref_inner(Type.expected_value(expected_type))

    inner_expected =
      unless array_expr?(expression) and slice_type?(expected_inner), do: expected_inner

    expr =
      case inner_expected do
        %Type{} = type -> lower_expr(expression, type, context)
        _none -> lower_expr(expression, context)
      end

    A.ref(expr)
  end

  defp lower_expected_expr_context(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Type{} = expected_type,
         %Context{} = context
       ) do
    Comprehension.lower_for_reduce_expr(expression, expected_type, context)
  end

  defp lower_expected_expr_context(
         {:for, _, args} = expression,
         %Type{} = expected_type,
         %Context{} = context
       )
       when is_list(args),
       do: Comprehension.lower_comprehension(expression, expected_type, context)

  defp lower_expected_expr_context(
         {:struct_literal, _, [path, fields]},
         %Type{} = expected_type,
         %Context{} = context
       ) do
    %AST.StructLiteral{
      path: lower_struct_literal_path(path, context),
      fields: lower_named_fields(fields, expected_type, context)
    }
  end

  defp lower_expected_expr_context(
         {:%{}, _, fields} = expression,
         %Type{kind: :resource} = expected_type,
         %Context{} = context
       )
       when is_list(fields) do
    inner = expected_type |> Type.inner() |> Type.expected_value()

    A.path_call([:ResourceArc, :new], [lower_expr(expression, inner, context)])
  end

  defp lower_expected_expr_context(
         {:%, _, [_module, {:%{}, _, fields}]} = expression,
         %Type{kind: :resource} = expected_type,
         %Context{} = context
       )
       when is_list(fields) do
    inner = expected_type |> Type.inner() |> Type.expected_value()

    A.path_call([:ResourceArc, :new], [lower_expr(expression, inner, context)])
  end

  # A tagged tuple or atom where a Rust enum is expected names its variant, as in
  # `{:float, value}` for `Value::Float(value)`.
  defp lower_expected_expr_context(
         expression,
         %Type{kind: :rust_enum, rust: rust_name} = type,
         context
       )
       when is_atom(expression) or (is_tuple(expression) and tuple_size(expression) == 2) or
              (is_tuple(expression) and elem(expression, 0) == :{}) do
    case rust_enum_variant(expression, type) do
      {variant, [], _types} ->
        A.path([rust_name, rust_variant(variant)])

      {variant, payloads, types} when length(payloads) == length(types) ->
        A.path_call(
          [rust_name, rust_variant(variant)],
          Enum.zip_with(payloads, types, &lower_expr(&1, &2, context))
        )

      _other ->
        lower_checked_expr(expression, type, context)
    end
  end

  # `ok(value)` where a result is expected lowers the value as its success type.
  defp lower_expected_expr_context(
         {:ok, _, [value]},
         %Type{kind: kind} = expected_type,
         %Context{} = context
       )
       when kind in [:result, :nif_result] do
    case Type.inner(expected_type) do
      %Type{} = inner -> A.ok(lower_expr(value, inner, context))
      nil -> A.ok(lower_expr(value, context))
    end
  end

  # `:ok` where nothing is expected is the unit value, as in `ok(:ok)`.
  defp lower_expected_expr_context(:ok, %Type{kind: :unit}, %Context{}),
    do: A.tuple([])

  # An atom where an atom-union enum is expected names its variant.
  defp lower_expected_expr_context(
         atom,
         %Type{kind: :enum, rust: rust_name, meta: %{variants: variants}},
         %Context{} = context
       )
       when is_atom(atom) and atom not in [nil, true, false] and is_list(variants) do
    if atom in variants,
      do: A.path([rust_name, rust_variant(atom)]),
      else: lower_expr(atom, context)
  end

  defp lower_expected_expr_context(
         {:%{}, _, [{:|, _, [base, fields]}]},
         %Type{} = _expected_type,
         %Context{} = context
       )
       when is_list(fields),
       do: lower_struct_update(base, fields, context)

  # A map literal where a reference to a map is expected builds the map and borrows it.
  defp lower_expected_expr_context(
         {:%{}, _, entries} = map,
         %Type{kind: :ref, meta: %{inner: %Type{} = inner}},
         %Context{} = context
       )
       when is_list(entries) do
    case Collection.keyed(inner) do
      {:map, _key, _value} -> A.ref(lower_expected_expr_context(map, inner, context))
      _other -> lower_expr(map, context)
    end
  end

  # A map literal where a map's alias is expected builds the map it names.
  defp lower_expected_expr_context(
         {:%{}, _, entries} = map,
         %Type{kind: :alias, meta: %{target: %Type{ast: %AST.TypePath{parts: parts}} = target}},
         %Context{} = context
       )
       when is_list(entries) and parts in [[:HashMap], [:BTreeMap]],
       do: lower_expected_expr_context(map, target, context)

  # A map literal where a map is expected builds one: `%{}` is `HashMap::new()`, and
  # `%{key => value}` is `HashMap::from([(key, value)])`.
  defp lower_expected_expr_context(
         {:%{}, _, entries},
         %Type{ast: %AST.TypePath{parts: parts, generics: [_key, _value]}} = expected_type,
         %Context{} = context
       )
       when is_list(entries) and parts in [[:HashMap], [:BTreeMap]] do
    case entries do
      [] ->
        A.path_call(parts ++ [:new])

      entries ->
        {:map, key, value} = Collection.keyed(expected_type)

        pairs =
          Enum.map(entries, fn {entry_key, entry_value} ->
            A.tuple([
              lower_expr(entry_key, key, context),
              lower_expr(entry_value, value, context)
            ])
          end)

        A.path_call(parts ++ [:from], [A.array(pairs)])
    end
  end

  defp lower_expected_expr_context(
         {:%{}, _, fields},
         %Type{kind: :struct, ast: %AST.TypePath{parts: parts}} = expected_type,
         %Context{} = context
       )
       when is_list(fields) do
    %AST.StructLiteral{
      path: A.path(parts),
      fields: lower_named_fields(fields, expected_type, context)
    }
  end

  defp lower_expected_expr_context(
         {:%, _, [_module, {:%{}, _, fields}]},
         %Type{kind: :struct, ast: %AST.TypePath{parts: parts}} = expected_type,
         %Context{} = context
       )
       when is_list(fields) do
    %AST.StructLiteral{
      path: A.path(parts),
      fields: lower_named_fields(fields, expected_type, context)
    }
  end

  defp lower_expected_expr_context(
         {:case, _, [expression, [do: clauses]]},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_case(expression, clauses, %{context | position: :expr}, expected_type)

  defp lower_expected_expr_context(
         {:if, _, [condition, branches]},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_if(condition, branches, %{context | position: :expr}, expected_type)

  defp lower_expected_expr_context(
         {:cond, _, [[do: clauses]]},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_cond(clauses, %{context | position: :expr}, expected_type)

  defp lower_expected_expr_context(
         {:with, _, clauses},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_with(clauses, %{context | position: :expr}, expected_type)

  defp lower_expected_expr_context(
         {:move, _, [{:fn, _, [{:->, _, [args, body]}]}]},
         %Type{} = expected_type,
         %Context{} = context
       ) do
    %{lower_expected_closure(args, body, context, expected_type) | move: true}
  end

  defp lower_expected_expr_context(
         {:fn, _, [{:->, _, [args, body]}]},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_expected_closure(args, body, context, expected_type)

  defp lower_expected_expr_context(
         {{:., _, [receiver, :decode]}, meta, []} = expression,
         %Type{} = expected_type,
         %Context{} = context
       ) do
    if Keyword.get(meta, :no_parens, false) do
      lower_expr_context(expression, context)
    else
      target =
        if expected_type.kind == :nif_result, do: Type.inner(expected_type), else: expected_type

      decoded = %AST.MethodCall{
        receiver: lower_checked_expr(receiver, rustler_term_type(), context),
        method: :decode,
        args: [],
        generics: [target.ast]
      }

      if expected_type.kind == :nif_result, do: decoded, else: A.try(decoded)
    end
  end

  defp lower_expected_expr_context(
         {:array, _, [values]},
         %Type{} = expected_type,
         %Context{} = context
       ) do
    array = %AST.ArrayLiteral{
      values: lower_expected_collection_values(values, expected_type, context)
    }

    if slice_type?(expected_type), do: A.ref(array), else: array
  end

  # A list literal where a slice is expected is a borrowed array, which allocates nothing.
  defp lower_expected_expr_context(values, %Type{} = expected_type, %Context{} = context)
       when is_list(values) do
    values = lower_expected_collection_values(values, expected_type, context)

    if slice_type?(expected_type),
      do: A.ref(%AST.ArrayLiteral{values: values}),
      else: A.vec(values)
  end

  defp lower_expected_expr_context(
         {:some, _, [expression]},
         %Type{} = expected_type,
         %Context{} = context
       ) do
    case expected_option_inner(expected_type) do
      %Type{} = inner_expected ->
        A.some(lower_option_some_expr(expression, inner_expected, context))

      nil ->
        lower_checked_expr({:some, [], [expression]}, expected_type, context)
    end
  end

  defp lower_expected_expr_context(
         {:{}, _, values},
         %Type{kind: :tuple, meta: %{elements: types}},
         %Context{} = context
       )
       when length(values) == length(types) do
    lower_expected_tuple(values, types, context)
  end

  defp lower_expected_expr_context(
         tuple,
         %Type{kind: :tuple, meta: %{elements: types}},
         %Context{} = context
       )
       when is_tuple(tuple) and tuple_size(tuple) == length(types) and tuple_size(tuple) != 3 do
    # A 3-tuple in Elixir's AST is a variable or a call, never a tuple literal.
    tuple
    |> Tuple.to_list()
    |> lower_expected_tuple(types, context)
  end

  defp lower_expected_expr_context(
         {:|>, _, [left, right]},
         %Type{} = expected_type,
         %Context{} = context
       ),
       do: lower_pipe(left, right, expected_type, context)

  # Arithmetic where an integer is expected computes in that integer, as its operands do.
  defp lower_expected_expr_context(
         {operator, _, [left, right]},
         %Type{kind: kind} = expected_type,
         %Context{} = context
       )
       when operator in [:+, :-, :*] and
              kind in [:i8, :i16, :i32, :i64, :isize, :u8, :u16, :u32, :u64, :usize] do
    A.binary(
      lower_expected_operand(left, expected_type, context),
      operator_op(operator),
      lower_expected_operand(right, expected_type, context)
    )
  end

  # A count is a `usize` where one is expected, not Elixir's integer.
  defp lower_expected_expr_context(
         {function, _, [_value] = args} = call,
         %Type{} = expected_type,
         context
       )
       when function in [:length, :byte_size, :map_size] do
    case BindingIndex.get(context.callables, nil, function, length(args)) do
      %RustQ.Binding.Callable{} -> lower_local_or_macro_call(function, args, context)
      nil -> Stdlib.lower!(call, stdlib_context(context, expected_type))
    end
  end

  defp lower_expected_expr_context(
         {{:., _, [receiver = {:__aliases__, _, [module]}, function]}, _, args} = call,
         %Type{} = expected_type,
         %Context{} = context
       )
       when module in @stdlib_modules do
    case Stdlib.lower(call, stdlib_context(context, expected_type)) do
      {:ok, lowered} -> lowered
      :unsupported -> lower_remote_or_method_call(receiver, function, args, context)
    end
  end

  # Collected where a slice is expected, values are collected into a vector and borrowed;
  # where an option or result is expected, the items collect into it, failing at the first
  # that fails.
  defp lower_expected_expr_context(
         {{:., _, [_receiver, :collect]}, _, []} = expression,
         %Type{} = expected_type,
         %Context{} = context
       ) do
    cond do
      slice_type?(Type.expected_value(expected_type)) ->
        A.ref(expression |> lower_expr(context) |> Comprehension.collect_as(@any_vec))

      expected_type.kind in [:option, :result] ->
        expression |> lower_expr(context) |> Comprehension.collect_as(expected_type.ast)

      true ->
        lower_checked_expr(expression, expected_type, context)
    end
  end

  # The closure `Option::map` or `and_then` takes gives the expected option's value, or the
  # expected option itself.
  defp lower_expected_expr_context(
         {{:., _, [receiver, method]}, _, [{:fn, _, [{:->, _, [[arg], body]}]}]} = expression,
         %Type{kind: :option} = expected_type,
         %Context{} = context
       )
       when method in [:map, :and_then] do
    case infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context)) do
      %Type{kind: :option} = receiver_type ->
        closure_return = if method == :map, do: Type.inner(expected_type), else: expected_type

        closure_context =
          context
          |> then(&closure_context([arg], &1))
          |> then(&LowerPattern.context_with_match_pattern(arg, Type.inner(receiver_type), &1))
          |> Map.merge(%{
            return_type: closure_return,
            scope_return_type: closure_return,
            position: :expr
          })

        A.method(lower_expr(receiver, context), method, [
          A.closure(
            [closure_arg!(arg)],
            lower_closure_body(body, closure_return, closure_context)
          )
        ])

      _other ->
        lower_checked_expr(expression, expected_type, context)
    end
  end

  # A NIF's `binary()` argument is a borrowed `Binary`; a `binary()` result owns its bytes.
  defp lower_expected_expr_context(
         {name, _, ast_context} = variable,
         %Type{kind: :binary, ast: %AST.TypeVec{}} = expected_type,
         %Context{} = context
       )
       when is_atom(name) and is_atom(ast_context) do
    case Map.get(context.vars, name) do
      %Type{ast: %AST.TypePath{parts: [:Binary]}} ->
        A.method(lower_expr(variable, context), :to_vec)

      _other ->
        lower_checked_expr(variable, expected_type, context)
    end
  end

  defp lower_expected_expr_context(expression, %Type{} = expected_type, %Context{} = context) do
    lower_checked_expr(expression, expected_type, context)
  end

  defp lower_expected_expr_context(expression, _expected_type, %Context{} = context),
    do: lower_expr(expression, context)

  defp lower_expected_collection_values(values, expected_type, context) do
    case collection_item_type(expected_type) do
      %Type{} = item_type -> Enum.map(values, &lower_list_item(&1, item_type, context))
      nil -> Enum.map(values, &lower_array_value(&1, context))
    end
  end

  # A value put in a new list while still in use, or still in its collection, is copied in.
  defp lower_list_item(value, %Type{} = item_type, context) do
    if in_use?(value, context) and not Collection.copy?(item_type),
      do: A.method(lower_expr(value, item_type, context), :clone),
      else: lower_expr(value, item_type, context)
  end

  @doc "The item type of a list a comprehension builds."
  def collection_item_type(type) do
    Type.vec_inner(Type.expected_value(type)) || Type.slice_inner(type)
  end

  defp expected_option_inner(%Type{kind: :option} = type), do: Type.inner(type)

  defp expected_option_inner(%Type{kind: :impl_trait, meta: %{traits: traits}}) do
    Enum.find_value(traits, fn
      %Type{meta: %{syn_name: "Into", args: [%Type{kind: :option} = option]}} ->
        Type.inner(option)

      %Type{} = trait ->
        expected_option_inner(trait)

      _trait ->
        nil
    end)
  end

  defp expected_option_inner(%Type{}), do: nil

  defp lower_option_some_expr(expression, %Type{} = inner_expected, %Context{} = context),
    do: lower_expr(expression, inner_expected, context)

  defp lower_expected_tuple(values, types, %Context{} = context) do
    A.tuple(
      values
      |> Enum.zip(types)
      |> Enum.map(fn {value, type} -> lower_expr(value, type, context) end)
    )
  end

  # `match?(pattern, value)` is the `case` that answers whether the value matches.
  # `__rustq_items__(list)`, which `RustQ.Meta.Desugar` leaves, iterates a list by reference
  # where it is borrowed or still in use, and takes it otherwise.
  defp lower_expr_context({:__rustq_items__, _, [list]}, %Context{} = context) do
    method = if borrowed_list?(list, context), do: :iter, else: :into_iter
    A.method(lower_expr(list, context), method)
  end

  # `__rustq_owned__(item, list)` is a copy of an item of `list`, as `.clone()` makes one of an
  # item that does not copy freely.
  defp lower_expr_context({:__rustq_owned__, _, [item, list]}, %Context{} = context) do
    inner =
      case Typing.synth(list, typing_env(context)) do
        %Type{} = type -> Type.vec_inner(type) || Type.slice_inner(type)
        nil -> nil
      end

    if Collection.copy?(inner),
      do: lower_expr(item, context),
      else: A.method(lower_expr(item, context), :clone)
  end

  # A block of expressions is a Rust block whose value is its last expression.
  defp lower_expr_context({:__block__, _, [_first, _second | _rest] = expressions}, context),
    do: A.block_expr(lower_value_block(expressions, context))

  defp lower_expr_context({:match?, meta, [pattern, expression]}, %Context{} = context) do
    clauses = [{:->, meta, [[pattern], true]}, {:->, meta, [[{:_, meta, nil}], false]}]
    lower_expr_context({:case, meta, [expression, [do: clauses]]}, context)
  end

  defp lower_expr_context({:unwrap!, _, [expression]}, %Context{} = context),
    do: A.try(lower_expr(expression, context))

  defp lower_expr_context({:ok_or!, _, [option, error]}, %Context{} = context) do
    A.try(A.method(lower_expr(option, context), :ok_or, [lower_nif_error(error, context)]))
  end

  defp lower_expr_context({:|>, _, [left, right]}, %Context{} = context),
    do: lower_pipe(left, right, context)

  defp lower_expr_context({:cast, _, [expression, type]}, %Context{} = context),
    do: A.cast(lower_cast_operand(expression, context), lower_type_arg(type, context))

  defp lower_expr_context({:decode_as!, _, [expression, type_ast]}, %Context{} = context),
    do: A.try(decode_as_expr(expression, type_ast, context))

  defp lower_expr_context({:decode_as, _, [expression, type_ast]}, %Context{} = context),
    do: decode_as_expr(expression, type_ast, context)

  # A borrowed list literal is a slice of an array, not of a vector built for the borrow.
  defp lower_expr_context({:ref, _, [values]}, %Context{} = context) when is_list(values),
    do: A.ref(%AST.ArrayLiteral{values: Enum.map(values, &lower_expr(&1, context))})

  defp lower_expr_context({:ref, _, [expression]}, %Context{} = context),
    do: A.ref(lower_expr(expression, context))

  defp lower_expr_context({:mut_ref, _, [expression]}, %Context{} = context),
    do: A.mut_ref(lower_expr(expression, context))

  defp lower_expr_context({:deref, _, [expression]}, %Context{} = context) do
    expr =
      expression
      |> Typing.synth(typing_env(context))
      |> deref_expected_type()
      |> case do
        %Type{} = expected -> lower_checked_expr(expression, expected, context)
        nil -> lower_expr(expression, context)
      end

    A.deref(expr)
  end

  defp lower_expr_context({:tuple_field, _, [expression, index]}, %Context{} = context)
       when is_integer(index),
       do: A.field(lower_expr(expression, context), index)

  defp lower_expr_context({:some, _, [expression]}, %Context{} = context),
    do: A.some(lower_some_arg_expr(expression, context))

  defp lower_expr_context({:none, _, []}, %Context{}), do: %AST.None{}
  defp lower_expr_context({:ok, _, []}, %Context{}), do: %AST.Ok{}

  defp lower_expr_context({:ok, _, [expression]}, %Context{} = context),
    do: A.ok(lower_expr(expression, context))

  defp lower_expr_context({:err, _, [expression]}, %Context{} = context),
    do: A.err(lower_expr(expression, context))

  defp lower_expr_context({:token_macro, _, [path, tokens]}, %Context{}),
    do: %AST.TokenMacro{path: lower_token_macro_path(path), tokens: tokens}

  defp lower_expr_context({:move, _, [{:fn, _, [{:->, _, [args, body]}]}]}, %Context{} = context),
    do: %{lower_closure_args(args, body, context) | move: true}

  defp lower_expr_context({:fn, _, [{:->, _, [args, body]}]}, %Context{} = context),
    do: args |> lower_closure_args(body, context) |> eta_reduced()

  defp lower_expr_context(
         {{:., _, [receiver = {:__aliases__, _, [module]}, function]}, _, args} = call,
         %Context{} = context
       )
       when module in @stdlib_modules do
    case Stdlib.lower(call, stdlib_context(context)) do
      {:ok, lowered} -> lowered
      :unsupported -> lower_remote_or_method_call(receiver, function, args, context)
    end
  end

  defp lower_expr_context({:expr!, _, [expression]}, %Context{} = context),
    do: lower_expr(expression, context)

  defp lower_expr_context({:pat!, _, [pattern]}, %Context{} = context),
    do: LowerPattern.lower_semantic_pat(pattern, context)

  defp lower_expr_context({:stmt!, _, [expression]}, %Context{} = context),
    do: A.stmt(lower_expr(expression, context))

  defp lower_expr_context({:raw_expr!, _, [tokens]}, %Context{}), do: parse_syn(:Expr, tokens)
  defp lower_expr_context({:raw_pat!, _, [tokens]}, %Context{}), do: parse_syn(:Pat, tokens)
  defp lower_expr_context({:raw_stmt!, _, [tokens]}, %Context{}), do: parse_syn(:Stmt, tokens)
  defp lower_expr_context({:raw_arm!, _, [tokens]}, %Context{}), do: parse_syn(:Arm, tokens)

  defp lower_expr_context({:arm!, _, [pattern, block]}, %Context{} = context),
    do: %AST.Arm{
      pattern: LowerPattern.lower_semantic_pat(pattern, context),
      body: lower_semantic_arm_body(block, context)
    }

  defp lower_expr_context({:nif_env, _, []}, %Context{}), do: A.path([:env])

  defp lower_expr_context({:badarg, _, []}, %Context{}),
    do: A.path([:rustler, :Error, :BadArg])

  defp lower_expr_context({:%{}, _, [{:|, _, [base, fields]}]}, %Context{} = context)
       when is_list(fields),
       do: lower_struct_update(base, fields, context)

  # An empty map whose type is left to Rust is a `HashMap` that later uses type.
  defp lower_expr_context({:%{}, _, []}, %Context{}), do: A.path_call([:HashMap, :new])

  defp lower_expr_context(
         {:__rustq_typed__, _, [expression, %Type{} = type]},
         %Context{} = context
       ),
       do: lower_expr(expression, type, context)

  defp lower_expr_context({:struct_literal, _, [path, fields]} = literal, %Context{} = context) do
    case declared_struct_type(path, context) do
      %Type{} = type ->
        lower_expected_expr_context(literal, type, context)

      nil ->
        %AST.StructLiteral{
          path: lower_struct_literal_path(path, context),
          fields: lower_named_fields(fields, context)
        }
    end
  end

  defp lower_expr_context({:enum_variant, _, [path, variant]}, %Context{} = context),
    do: enum_variant_path(path, variant, context)

  defp lower_expr_context({:enum_variant, _, [path, variant | args]}, %Context{} = context) do
    %AST.PathCall{
      path: enum_variant_path(path, variant, context),
      args: Enum.map(args, &lower_expr(&1, context))
    }
  end

  defp lower_expr_context({:array, _, [values]}, %Context{} = context),
    do: %AST.ArrayLiteral{values: Enum.map(values, &lower_array_value(&1, context))}

  defp lower_expr_context(
         {:repeat, _, [{group, _, ast_context}, [do: expression]]},
         %Context{} = context
       )
       when is_atom(group) and is_atom(ast_context),
       do: repeat_expression(group, expression, context)

  defp lower_expr_context({:index, _, [receiver, index]}, %Context{} = context),
    do: A.index(lower_expr(receiver, context), lower_expr(index, context))

  # `container[key]` indexes; a map is indexed by a reference to its key.
  # A map is indexed by a borrowed key.
  defp lower_expr_context({{:., _, [Access, :get]}, _, [receiver, key]}, %Context{} = context) do
    receiver_type =
      infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))

    index =
      case Collection.keyed(receiver_type) do
        {:map, _key, _value} -> borrowed_key(key, context)
        _list -> lower_expr(key, RustQ.Spec.type(quote(do: RustQ.Type.usize())), context)
      end

    A.index(lower_expr(receiver, context), index)
  end

  defp lower_expr_context({:&, _, [{:/, _, [function, arity]}]}, %Context{} = context)
       when is_integer(arity),
       do: lower_function_capture(function, context)

  # `&(&1 + &2)` is a closure of its numbered arguments.
  defp lower_expr_context({:&, _, [_body]} = capture, %Context{} = context),
    do: capture |> Capture.expand() |> lower_expr(context)

  defp lower_expr_context({function, _, args} = call, %Context{} = context)
       when function in [
              :..,
              :..//,
              :in,
              :==,
              :!=,
              :<,
              :<=,
              :>,
              :>=,
              :+,
              :-,
              :*,
              :/,
              :not,
              :div,
              :rem,
              :and,
              :or,
              :abs,
              :min,
              :max,
              :byte_size,
              :length,
              :map_size,
              :elem,
              :put_elem,
              :tuple_size,
              :is_nil
            ] and is_list(args) do
    case BindingIndex.get(context.callables, nil, function, length(args)) do
      %RustQ.Binding.Callable{} -> lower_local_or_macro_call(function, args, context)
      nil -> Stdlib.lower!(call, stdlib_context(context))
    end
  end

  defp lower_expr_context(
         {{:., _, [{:__aliases__, _, [:Bitwise]}, :bsr]}, _, [left, right]},
         %Context{} = context
       ),
       do: lower_binary_op(left, :shr, right, context)

  defp lower_expr_context(
         {{:., _, [{:__aliases__, _, [:Bitwise]}, :band]}, _, [left, right]},
         %Context{} = context
       ),
       do: lower_binary_op(left, :bitand, right, context)

  defp lower_expr_context({:if, _, [condition, branches]}, %Context{} = context),
    do: lower_if(condition, branches, %{context | position: :expr})

  defp lower_expr_context({:cond, _, [[do: clauses]]}, %Context{} = context),
    do: lower_cond(clauses, %{context | position: :expr})

  defp lower_expr_context({:case, _, [expression, [do: clauses]]}, %Context{} = context),
    do: lower_case(expression, clauses, %{context | position: :expr})

  defp lower_expr_context({:with, _, clauses}, %Context{} = context),
    do: lower_with(clauses, %{context | position: :expr})

  defp lower_expr_context(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Context{} = context
       ),
       do: Comprehension.lower_for_reduce_expr(expression, context)

  defp lower_expr_context({:for, _, args} = expression, %Context{} = context)
       when is_list(args),
       do: Comprehension.lower_comprehension(expression, nil, context)

  defp lower_expr_context(
         {{:., _meta, [receiver, field_or_function]}, call_meta, []},
         %Context{} = context
       ) do
    lower_dot_expr(receiver, field_or_function, call_meta, context)
  end

  defp lower_expr_context({{:., _meta, [receiver, function]}, _, args}, %Context{} = context) do
    lower_remote_or_method_call(receiver, function, args, context)
  end

  defp lower_expr_context({:__rustq_path__, _, parts}, %Context{}), do: A.path(parts)

  defp lower_expr_context({:__aliases__, _, parts}, %Context{} = context),
    do: A.path(Paths.mapped_alias_parts(parts, context.rust_modules))

  defp lower_expr_context({:{}, _, values}, %Context{} = context),
    do: A.tuple(Enum.map(values, &lower_expr(&1, context)))

  defp lower_expr_context({left, right}, %Context{} = context),
    do: A.tuple([lower_expr(left, context), lower_expr(right, context)])

  defp lower_expr_context({name, _, args}, %Context{} = context)
       when is_atom(name) and is_list(args) do
    lower_local_or_macro_call(name, args, context)
  end

  defp lower_expr_context({name, _, ast_context}, %Context{} = context)
       when is_atom(name) and is_atom(ast_context) do
    lower_var_or_macro_capture(name, ast_context, context)
  end

  defp lower_expr_context(values, %Context{} = context) when is_list(values),
    do: A.vec(Enum.map(values, &lower_array_value(&1, context)))

  defp lower_expr_context(value, %Context{}) when is_binary(value), do: A.lit(value)

  defp lower_expr_context(value, %Context{}) when is_integer(value) or is_float(value),
    do: A.lit(value)

  defp lower_expr_context(true, %Context{}), do: A.lit(true)
  defp lower_expr_context(false, %Context{}), do: A.lit(false)
  defp lower_expr_context(nil, %Context{}), do: %AST.None{}
  defp lower_expr_context(atom, %Context{}) when is_atom(atom), do: %AST.AtomValue{name: atom}

  defp lower_expr_context(other, %Context{}) do
    Diagnostic.lower(
      :unsupported_expression,
      other,
      "unsupported defrust expression",
      suggestion:
        "Use ordinary Rusty-Elixir forms, add a lowering clause, or use raw_expr! as an explicit escape hatch."
    )
  end

  defp lower_statement_expr(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Context{return_type: %Type{}} = context
       ) do
    A.try(Comprehension.lower_for_reduce_expr(expression, context))
  end

  defp lower_statement_expr(expression, %Context{return_type: %Type{} = return_type} = context) do
    if infer_statement_propagation?(expression, return_type, context) do
      A.try(lower_expr(expression, context))
    else
      lower_expr(expression, context)
    end
  end

  defp lower_statement_expr(expression, %Context{} = context), do: lower_expr(expression, context)

  defp infer_statement_propagation?(expression, %Type{} = return_type, %Context{} = context) do
    same_wrapper_propagation?(expression, return_type, context)
  end

  defp lower_wrapper_arg_expr(expression, %Context{} = context) do
    if same_wrapper_propagation?(expression, context.return_type, context) do
      A.try(lower_expr(expression, context))
    else
      lower_expr(expression, context)
    end
  end

  defp lower_some_arg_expr(expression, %Context{} = context) do
    if fallible_expression?(expression, context) and propagation_allowed?(context.return_type) do
      A.try(lower_expr(expression, context))
    else
      lower_wrapper_arg_expr(expression, context)
    end
  end

  defp propagation_allowed?(%Type{} = type), do: Type.propagates?(type)
  defp propagation_allowed?(nil), do: true
  defp propagation_allowed?(_type), do: false

  # A literal is a plain value whatever type the context expects.
  defp fallible_expression?(literal, %Context{})
       when is_number(literal) or is_binary(literal) or is_boolean(literal),
       do: false

  # An operator's operands propagate on their own; the result is a plain value.
  defp fallible_expression?({operator, _, [_left, _right]}, %Context{})
       when operator in [:+, :-, :*, :/, :==, :!=, :<, :<=, :>, :>=, :and, :or, :div, :rem],
       do: false

  defp fallible_expression?(expression, %Context{} = context) do
    case Typing.synth(expression, typing_env(context)) do
      %Type{} = type -> Type.propagates?(type)
      nil -> false
    end
  end

  defp lower_cast_operand(expression, %Context{} = context) do
    if same_wrapper_propagation?(expression, context.return_type, context) do
      A.try(lower_expr(expression, context))
    else
      lower_expr(expression, context)
    end
  end

  defp same_wrapper_propagation?(expression, %Type{} = return_type, %Context{} = context) do
    case Paths.callable_return_type(expression,
           callables: context.callables,
           rust_modules: context.rust_modules,
           vars: context.vars
         ) do
      %Type{kind: kind} = call_type ->
        Type.propagates?(call_type) and Type.propagates?(return_type) and kind == return_type.kind

      _unknown_or_plain ->
        false
    end
  end

  defp same_wrapper_propagation?(_expression, _return_type, _context), do: false

  defp infer_propagation?(expression, %Type{} = expected_type, %Context{} = context) do
    match?(%Typing.Check{coercion: :propagate}, typing_check(expression, expected_type, context))
  end

  defp lower_checked_expr(expression, %Type{} = expected_type, %Context{} = context) do
    typing_check(expression, expected_type, context)
    |> lower_checked_coercion(expression, context)
  end

  # `?` needs a function returning an option or result; a plain value keeps it wrapped.
  defp lower_checked_coercion(%Typing.Check{coercion: coercion}, expression, context)
       when coercion in [:propagate, :propagate_borrow, :propagate_mut_borrow, :propagate_as_ref] and
              is_struct(context.scope_return_type, Type) and
              context.scope_return_type.kind not in [:option, :result, :nif_result, :unit],
       do: lower_expr(expression, context)

  defp lower_checked_coercion(%Typing.Check{coercion: :propagate} = check, expression, context) do
    if option_propagation_in_result_context?(check, context) do
      lower_expr(expression, context)
    else
      A.try(lower_expr(expression, context))
    end
  end

  # An expression the author already borrowed is not borrowed again.
  defp lower_checked_coercion(
         %Typing.Check{coercion: coercion},
         {borrow, _, [_]} = expression,
         context
       )
       when coercion in [:borrow, :mut_borrow] and borrow in [:ref, :mut_ref],
       do: lower_expr(expression, context)

  defp lower_checked_coercion(%Typing.Check{coercion: :borrow}, expression, context),
    do: A.ref(lower_expr(expression, context))

  defp lower_checked_coercion(%Typing.Check{coercion: :mut_borrow}, expression, context),
    do: A.mut_ref(lower_expr(expression, context))

  defp lower_checked_coercion(%Typing.Check{coercion: :propagate_borrow}, expression, context),
    do: A.ref(A.try(lower_expr(expression, context)))

  defp lower_checked_coercion(
         %Typing.Check{coercion: :propagate_mut_borrow},
         expression,
         context
       ),
       do: A.mut_ref(A.try(lower_expr(expression, context)))

  defp lower_checked_coercion(%Typing.Check{coercion: :as_ref}, expression, context),
    do: option_as_ref_expr(lower_expr(expression, context))

  defp lower_checked_coercion(%Typing.Check{coercion: :propagate_as_ref}, expression, context),
    do: option_as_ref_expr(A.try(lower_expr(expression, context)))

  defp lower_checked_coercion(%Typing.Check{coercion: :deref}, expression, context),
    do: A.deref(lower_expr(expression, context))

  defp lower_checked_coercion(%Typing.Check{coercion: :some}, expression, context),
    do: A.some(lower_expr(expression, context))

  defp lower_checked_coercion(%Typing.Check{coercion: :to_vec}, expression, context),
    do: A.method(lower_expr(expression, context), :to_vec)

  defp lower_checked_coercion(%Typing.Check{}, expression, context),
    do: lower_expr(expression, context)

  defp option_as_ref_expr(expr) do
    A.method(expr, :as_ref)
  end

  defp option_propagation_in_result_context?(
         %Typing.Check{type: %Type{kind: :option}},
         %Context{return_type: %Type{kind: kind}}
       )
       when kind in [:result, :nif_result],
       do: true

  defp option_propagation_in_result_context?(%Typing.Check{}, %Context{}), do: false

  defp typing_check(expression, %Type{} = expected_type, %Context{} = context) do
    Typing.check(expression, expected_type, typing_env(context))
  end

  defp lower_case(expression, clauses, %Context{} = context, expected_type \\ nil) do
    clauses = normalize_case_clauses(clauses)

    expression_type =
      infer_expr_type(expression, context.vars) || Typing.synth(expression, typing_env(context))

    {case_type, match_expr} = case_scrutinee(expression, expression_type, clauses, context)
    case_type = declared_case_type(case_type, context)

    arms =
      Enum.map(clauses, fn {:->, _, [[pattern], body]} ->
        {pattern, guard} = LowerPattern.split_guarded_pattern(pattern)
        body_context = LowerPattern.context_with_match_pattern(pattern, case_type, context)
        body = lower_clause_body(body, body_context, expected_type)

        mutable_vars =
          body |> LowerPattern.collect_pattern_mutations(body_context) |> MapSet.new()

        %AST.Arm{
          pattern:
            pattern
            |> LowerPattern.lower_match_pattern(case_type, context)
            |> Mutability.mark_mutable_pattern_vars(mutable_vars),
          guard: lower_guard_expr(guard, body_context),
          body: body
        }
      end)

    A.match_expr(match_expr, arms)
  end

  defp case_scrutinee(
         expression,
         %Type{kind: :vec} = expression_type,
         clauses,
         %Context{} = context
       ) do
    match_expr = lower_expr(expression, context)

    if Enum.any?(clauses, &list_case_clause?/1) do
      {expression_type, A.method(match_expr, :as_slice)}
    else
      {expression_type, match_expr}
    end
  end

  # An option field reached through a reference is matched by reference, as what it holds
  # cannot be moved out.
  defp case_scrutinee(expression, %Type{} = expression_type, clauses, %Context{} = context) do
    cond do
      propagate_case_scrutinee?(expression_type, clauses) ->
        inner = Type.inner(expression_type)
        {inner, lower_checked_expr(expression, inner, context)}

      lent_field?(expression, expression_type, context) ->
        {Type.ref(expression_type), A.ref(lower_expr(expression, context))}

      true ->
        {expression_type, lower_expr(expression, context)}
    end
  end

  defp case_scrutinee(expression, _expression_type, clauses, %Context{} = context) do
    {LowerPattern.infer_case_type_from_patterns(clauses), lower_expr(expression, context)}
  end

  defp list_case_clause?({:->, _, [[pattern], _body]}) do
    {pattern, _guard} = LowerPattern.split_guarded_pattern(pattern)
    LowerPattern.list_pattern?(pattern)
  end

  defp propagate_case_scrutinee?(%Type{} = expression_type, clauses) do
    Type.propagates?(expression_type) and
      not LowerPattern.wrapper_case_patterns?(expression_type, clauses)
  end

  defp normalize_case_clauses({:__block__, _meta, clauses}), do: clauses
  defp normalize_case_clauses(clauses), do: clauses

  defp lower_if(condition, branches, %Context{} = context, expected_type \\ nil) do
    then_body = Keyword.fetch!(branches, :do)
    else_body = Keyword.get(branches, :else)

    %AST.If{
      condition: lower_condition(condition, context),
      then: lower_clause_body(then_body, context, expected_type),
      else: lower_clause_body(else_body, context, expected_type)
    }
  end

  defp lower_cond(clauses, %Context{} = context, expected_type \\ nil) do
    clauses
    |> normalize_case_clauses()
    |> lower_cond_clauses(context, expected_type)
  end

  defp lower_cond_clauses([{:->, _, [[true], body]}], context, expected_type),
    do: clause_expr(body, context, expected_type)

  defp lower_cond_clauses([{:->, _, [[condition], body]} | rest], context, expected_type) do
    %AST.If{
      condition: lower_condition(condition, context),
      then: lower_clause_body(body, context, expected_type),
      else: [A.return_stmt(lower_cond_clauses(rest, context, expected_type))]
    }
  end

  defp lower_cond_clauses(other, _context, _expected_type) do
    Diagnostic.lower(
      :unsupported_cond,
      other,
      "unsupported defrust cond expression",
      suggestion: "End cond with a true clause so the generated Rust expression is exhaustive."
    )
  end

  defp clause_expr(body, context, %Type{} = expected_type) do
    body
    |> block_expressions()
    |> lower_expected_value_block(context, expected_type)
  end

  defp clause_expr(body, context, _expected_type) do
    case body |> block_expressions() |> lower_value_block(context) do
      [%AST.Return{expr: expr}] -> expr
      statements -> A.block_expr(statements)
    end
  end

  defp lower_expected_value_block(expressions, %Context{} = context, %Type{} = expected_type) do
    case lower_expected_block(expressions, context, expected_type) do
      [%AST.Return{expr: expr}] -> expr
      statements -> A.block_expr(statements)
    end
  end

  # A condition is a boolean; a borrowed one is read.
  defp lower_condition(condition, %Context{} = context) do
    case infer_expr_type(condition, context.vars) ||
           Typing.synth(condition, typing_env(context)) do
      %Type{kind: :ref} -> A.deref(lower_expr(condition, context))
      _owned -> lower_binary_operand(condition, context)
    end
  end

  defp lower_with(clauses, %Context{} = context, expected_type \\ nil) do
    {matches, body_opts} = Enum.split_while(clauses, &match?({:<-, _, _}, &1))
    body_opts = unwrap_with_body_opts(body_opts)
    body = Keyword.fetch!(body_opts, :do)
    else_clauses = Keyword.get(body_opts, :else, [])

    lower_with_matches(matches, body, else_clauses, context, expected_type)
  end

  defp unwrap_with_body_opts([opts]) when is_list(opts), do: opts
  defp unwrap_with_body_opts(opts), do: opts

  defp lower_with_matches([], body, _else_clauses, %Context{} = context, expected_type) do
    body
    |> lower_clause_body(%{context | position: :return}, expected_type)
    |> block_expr()
  end

  defp lower_with_matches(
         [{:<-, _, [pattern, expression]} | rest],
         body,
         else_clauses,
         %Context{} = context,
         expected_type
       ) do
    with_value = :__rustq_with_value

    match_type =
      Paths.callable_return_type(expression,
        callables: context.callables,
        rust_modules: context.rust_modules,
        vars: context.vars
      ) || infer_expr_type(expression, context.vars) ||
        Typing.synth(expression, typing_env(context))

    match_type = declared_case_type(match_type, context)
    body_context = LowerPattern.context_with_match_pattern(pattern, match_type, context)

    A.match_expr(lower_expr(expression, context), [
      %AST.Arm{
        pattern: LowerPattern.lower_with_pattern(pattern, match_type, context),
        body: [
          A.return_stmt(lower_with_matches(rest, body, else_clauses, body_context, expected_type))
        ]
      },
      with_fallback_arm(with_value, pattern, else_clauses, context, expected_type)
    ])
  end

  # Without `else`, an unmatched result or option passes its error or `None` on, as in Elixir.
  defp with_fallback_arm(_value_name, {:ok, _value}, [], _context, _expected_type),
    do: passthrough_arm(%AST.PatErr{pattern: %AST.PatVar{name: :error}}, A.err(A.var(:error)))

  defp with_fallback_arm(_value_name, {:some, _value}, [], _context, _expected_type),
    do: passthrough_arm(%AST.PatNone{}, %AST.None{})

  # A lone catch-all `else` is the fallback arm itself, not a match on the unmatched value.
  defp with_fallback_arm(
         _value_name,
         _pattern,
         [{:->, _, [[{:_, _, _}], body]}],
         context,
         expected_type
       ) do
    %AST.Arm{
      pattern: %AST.PatWildcard{},
      body: lower_clause_body(body, %{context | position: :return}, expected_type)
    }
  end

  defp with_fallback_arm(value_name, _pattern, else_clauses, context, expected_type) do
    %AST.Arm{
      pattern: %AST.PatVar{name: value_name},
      body: [
        A.return_stmt(lower_with_else(value_name, else_clauses, context, expected_type))
      ]
    }
  end

  defp passthrough_arm(pattern, expr),
    do: %AST.Arm{pattern: pattern, body: [A.return_stmt(expr)]}

  defp lower_with_else(value_name, [], _context, _expected_type), do: A.var(value_name)

  defp lower_with_else(value_name, else_clauses, %Context{} = context, expected_type) do
    A.match_expr(
      A.var(value_name),
      Enum.map(else_clauses, fn {:->, _, [[pattern], body]} ->
        %AST.Arm{
          pattern: LowerPattern.lower_match_pattern(pattern, nil, context),
          body: lower_clause_body(body, %{context | position: :return}, expected_type)
        }
      end)
    )
  end

  defp lower_assignment(target, {op, _meta, [left, right]}, expected_type, %Context{} = context)
       when op in [:+, :-, :*, :/] do
    lower_assignment_op(target, op, left, right, expected_type, context)
  end

  defp lower_assignment(
         target,
         {{:., _, [{:__aliases__, _, [:Bitwise]}, op]}, _, [left, right]},
         expected_type,
         %Context{} = context
       )
       when op in [:bsr, :band] do
    lower_assignment_op(target, op, left, right, expected_type, context)
  end

  defp lower_assignment(target, expression, expected_type, %Context{} = context) do
    A.assign(lower_expr(target, context), lower_expr(expression, expected_type, context))
  end

  defp lower_assignment_op(target, op, left, right, expected_type, %Context{} = context) do
    lowered_target = lower_expr(target, context)
    lowered_left = lower_expr(left, context)

    if lowered_target == lowered_left do
      %AST.AssignOp{
        target: lowered_target,
        op: operator_op(op),
        expr: lower_expr(right, expected_type, context)
      }
    else
      A.assign(lowered_target, lower_expr({op, [], [left, right]}, expected_type, context))
    end
  end

  defp lower_option_if_let_statement(expression, clauses, %Context{} = context) do
    lower_result_if_let_statement(expression, clauses, context) ||
      lower_some_if_let_statement(expression, clauses, context) ||
      lower_single_arm_if_let_statement(expression, clauses, context)
  end

  # A case run for one pattern, whose other branch does nothing, is an `if let`.
  defp lower_single_arm_if_let_statement(
         expression,
         [{:->, _, [[pattern], body]}, {:->, _, [[{:_, _, _}], fallback]}] = clauses,
         %Context{} = context
       ) do
    if unit_body?(fallback) and not match?({:when, _, _}, pattern) do
      expression_type =
        infer_expr_type(expression, context.vars) || Typing.synth(expression, typing_env(context))

      {case_type, match_expr} = case_scrutinee(expression, expression_type, clauses, context)
      case_type = declared_case_type(case_type, context)
      then_context = LowerPattern.context_with_match_pattern(pattern, case_type, context)
      then_body = lower_clause_body(body, then_context)

      mutable_vars =
        then_body |> LowerPattern.collect_pattern_mutations(then_context) |> MapSet.new()

      %AST.IfLet{
        pattern:
          pattern
          |> LowerPattern.lower_match_pattern(case_type, context)
          |> Mutability.mark_mutable_pattern_vars(mutable_vars),
        expr: match_expr,
        then: then_body
      }
    end
  end

  defp lower_single_arm_if_let_statement(_expression, _clauses, %Context{}), do: nil

  defp lower_result_if_let_statement(
         expression,
         [{:->, _, [[{:ok, _} = pattern], body]}, {:->, _, [[{:error, {:_, _, _}}], fallback]}],
         context
       ) do
    if unit_body?(fallback) do
      type = Typing.synth(expression, typing_env(context))
      context = LowerPattern.context_with_match_pattern(pattern, type, context)
      body = lower_clause_body(body, context)
      mutable = body |> LowerPattern.collect_pattern_mutations(context) |> MapSet.new()

      %AST.IfLet{
        pattern:
          pattern
          |> LowerPattern.lower_match_pattern(%Type{kind: :result}, context)
          |> Mutability.mark_mutable_pattern_vars(mutable),
        expr: lower_expr(expression, context),
        then: body
      }
    end
  end

  defp lower_result_if_let_statement(_expression, _clauses, _context), do: nil

  defp lower_some_if_let_statement(expression, clauses, %Context{} = context) do
    with [{:some, some_pattern, some_body}, {:none, none_body}] <- option_if_let_clauses(clauses),
         true <- unit_body?(none_body) do
      expression_type = Typing.synth(expression, typing_env(context)) || %Type{kind: :option}
      option_type = propagated_option_type(expression_type) || expression_type
      then_context = LowerPattern.context_with_match_pattern(some_pattern, option_type, context)
      then_body = lower_clause_body(some_body, then_context)
      mutable_vars = then_body |> LowerPattern.collect_mut_refs() |> MapSet.new()

      %AST.IfLet{
        pattern:
          some_pattern
          |> LowerPattern.lower_match_pattern(%Type{kind: :option}, context)
          |> Mutability.mark_mutable_pattern_vars(mutable_vars),
        expr: lower_option_case_scrutinee(expression, expression_type, option_type, context),
        then: then_body
      }
    else
      _other -> nil
    end
  end

  defp propagated_option_type(%Type{} = expression_type) do
    case Type.inner(expression_type) do
      %Type{kind: :option} = option_type ->
        if Type.propagates?(expression_type), do: option_type

      _not_fallible_option ->
        nil
    end
  end

  defp lower_option_case_scrutinee(
         expression,
         %Type{} = expression_type,
         %Type{} = option_type,
         context
       ) do
    if Type.propagates?(expression_type) and Type.inner(expression_type) == option_type do
      lower_checked_expr(expression, option_type, context)
    else
      lower_expr(expression, option_type, context)
    end
  end

  defp option_if_let_clauses(clauses) do
    Enum.map(clauses, fn
      {:->, _, [[{:some, _pattern} = pattern], body]} -> {:some, pattern, body}
      {:->, _, [[{:{}, _, [:some, _pattern]} = pattern], body]} -> {:some, pattern, body}
      {:->, _, [[:none], body]} -> {:none, body}
      {:->, _, [[nil], body]} -> {:none, body}
      _other -> :unsupported
    end)
  end

  defp unit_body?(body) do
    body
    |> block_expressions()
    |> Enum.all?(&(&1 in [:ok, nil]))
  end

  # A list borrowed, or owned but still in use, is iterated by reference.
  defp borrowed_list?(list, context) do
    case Typing.synth(list, typing_env(context)) do
      %Type{kind: kind} when kind in [:slice, :ref, :mut_ref] -> true
      _owned -> in_use?(list, context)
    end
  end

  # An option field holding what cannot be copied, reached through a reference.
  defp lent_field?(expression, %Type{kind: :option} = type, %Context{} = context) do
    case root_variable_node(expression) do
      {name, _meta, _context} ->
        behind_reference?(expression, name, context) and not Collection.copy?(Type.inner(type))

      nil ->
        false
    end
  end

  defp lent_field?(_expression, _type, _context), do: false

  defp behind_reference?({name, _, ast_context}, name, _context) when is_atom(ast_context),
    do: false

  defp behind_reference?(_field, name, %Context{vars: vars}),
    do: match?(%Type{kind: kind} when kind in [:ref, :mut_ref], Map.get(vars, name))

  defp root_variable_node({name, _, ast_context} = variable)
       when is_atom(name) and is_atom(ast_context),
       do: variable

  defp root_variable_node({{:., _, [receiver, _field]}, meta, []}),
    do: if(meta[:no_parens], do: root_variable_node(receiver))

  defp root_variable_node(_collection), do: nil

  defp block_expr([%AST.Return{expr: expr}]), do: expr

  defp block_expr(statements) do
    A.block_expr(statements)
  end

  @doc "Lowers the body of a clause, expected to give `type` when known."
  def lower_clause_body(body, %Context{position: :statement} = context) do
    expressions = block_expressions(body)
    context = context_with_downstream_let_types(expressions, context)

    expressions
    |> Enum.map(&lower_statement(&1, context))
    |> reject_unit_statements()
  end

  def lower_clause_body(body, %Context{position: :return} = context) do
    body
    |> block_expressions()
    |> lower_block(context)
  end

  def lower_clause_body(body, %Context{position: :expr} = context) do
    body
    |> block_expressions()
    |> lower_block(%{context | return_type: nil})
  end

  def lower_clause_body(body, %Context{position: :expr} = context, %Type{} = expected_type) do
    body
    |> block_expressions()
    |> lower_expected_block(%{context | return_type: expected_type}, expected_type)
  end

  def lower_clause_body(body, %Context{position: :return} = context, %Type{} = expected_type) do
    if Type.propagates?(expected_type) do
      lower_clause_body(body, context)
    else
      body
      |> block_expressions()
      |> lower_expected_block(%{context | return_type: expected_type}, expected_type)
    end
  end

  def lower_clause_body(body, %Context{} = context, _expected_type),
    do: lower_clause_body(body, context)

  defp reject_unit_statements(statements) do
    Enum.reject(statements, fn
      %AST.ExprStmt{expr: %AST.Tuple{values: []}} -> true
      _other -> false
    end)
  end

  defp lower_guard_expr(nil, %Context{}), do: nil
  defp lower_guard_expr(guard, %Context{} = context), do: lower_expr(guard, context)

  defp lower_dot_expr(receiver, field_or_function, call_meta, %Context{} = context) do
    no_parens? = Keyword.get(call_meta, :no_parens, false)

    cond do
      no_parens? and Paths.alias_path_ast?(receiver) ->
        A.path(Paths.alias_path_parts(receiver, context.rust_modules) ++ [field_or_function])

      no_parens? ->
        A.field(lower_expr(receiver, context), field_or_function)

      Paths.super_alias_ast?(receiver) ->
        A.path_call([:super, field_or_function])

      Paths.alias_ast?(receiver) ->
        A.path_call(Paths.alias_parts(receiver, context.rust_modules) ++ [field_or_function])

      field_or_function == :into_iter ->
        receiver_type =
          infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))

        receiver
        |> lower_dot_receiver(:into_iter, context)
        |> Collection.iterated(borrowed_iteration(:into_iter, [], receiver_type))

      true ->
        %AST.MethodCall{
          receiver: lower_dot_receiver(receiver, field_or_function, context),
          method: field_or_function
        }
    end
  end

  defp lower_dot_receiver(receiver, :ok, %Context{} = context), do: lower_expr(receiver, context)

  defp lower_dot_receiver(
         {{:., _, [_term, :map_get]}, _, [_key]} = receiver,
         _method,
         %Context{} = context
       ),
       do: A.try(lower_expr(receiver, context))

  defp lower_dot_receiver(receiver, :clone, %Context{} = context) do
    receiver_type =
      infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))

    lower_method_receiver(receiver, receiver_type, :clone, context)
  end

  defp lower_dot_receiver(receiver, _method, %Context{} = context),
    do: lower_expr(receiver, context)

  defp lower_remote_or_method_call(receiver, function, args, %Context{} = context) do
    cond do
      macro_call_name?(function) ->
        lower_remote_macro_call(receiver, function, args, context)

      Paths.super_alias_ast?(receiver) ->
        A.path_call([:super, function], lower_parent_call_args(function, args, context))

      Paths.rust_constructor_alias?(receiver) ->
        path = Paths.alias_parts(receiver, context.rust_modules) ++ [rust_variant(function)]

        A.path_call(path, lower_path_call_args(path, function, args, context))

      Paths.alias_ast?(receiver) ->
        path = Paths.alias_parts(receiver, context.rust_modules) ++ [function]

        A.path_call(path, lower_path_call_args(path, function, args, context))

      true ->
        receiver_type =
          infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))

        target = Paths.callable_target_from_type(receiver_type)

        A.method(
          lower_method_receiver(receiver, receiver_type, function, context),
          borrowed_iteration(function, args, receiver_type),
          lower_method_call_args(receiver_type, target, function, args, context)
        )
    end
  end

  defp lower_method_receiver(
         {{:., _, [_term, :map_get]}, _, [_key]} = receiver,
         _receiver_type,
         _function,
         %Context{} = context
       ) do
    A.try(lower_expr(receiver, context))
  end

  defp lower_method_receiver(receiver, %Type{} = receiver_type, :unwrap_or, %Context{} = context) do
    case Type.inner(receiver_type) do
      %Type{kind: :option} = option_type ->
        if Type.propagates?(receiver_type) do
          lower_checked_expr(receiver, option_type, context)
        else
          lower_expr(receiver, context)
        end

      _other ->
        lower_expr(receiver, context)
    end
  end

  # A fallible receiver of a method its result lacks, as `decoder.read_bool().encode(env)`,
  # propagates its error first, as a fallible operand does.
  # Cloning a reference to a reference clones what it refers to, the value Elixir means.
  defp lower_method_receiver(receiver, %Type{kind: :ref} = receiver_type, :clone, context) do
    case Type.ref_inner(receiver_type) do
      %Type{kind: :ref} -> A.deref(lower_expr(receiver, context))
      _value -> lower_expr(receiver, context)
    end
  end

  defp lower_method_receiver(receiver, receiver_type, function, %Context{} = context) do
    if fallible_receiver?(receiver_type, function, context),
      do: A.try(lower_expr(receiver, context)),
      else: lower_expr(receiver, context)
  end

  defp fallible_receiver?(%Type{kind: kind}, function, %Context{} = context)
       when kind in [:result, :nif_result],
       do: function not in @wrapper_methods and propagation_allowed?(context.return_type)

  defp fallible_receiver?(_receiver_type, _function, %Context{}), do: false

  defp lower_local_or_macro_call(name, args, %Context{} = context) do
    cond do
      macro_call_name?(name) ->
        lower_macro_call(name, args, context.rust_macros, context)

      macro_var_fragment(name, context.macro_vars) == :ident ->
        %AST.LocalCall{name: :"$#{name}", args: lower_call_args(nil, name, args, context)}

      true ->
        %AST.LocalCall{name: name, args: lower_call_args(nil, name, args, context)}
    end
  end

  defp lower_var_or_macro_capture(name, ast_context, %Context{} = context) do
    case macro_var_fragment(name, context.macro_vars) do
      nil ->
        A.var(name)

      :ty ->
        Diagnostic.lower(
          :macro_variable_wrong_position,
          {name, [], ast_context},
          "macro variable #{name} is a Rust type fragment, but this is an expression position",
          suggestion: "Use #{name} in a type position such as decode_as(value, #{name})."
        )

      _fragment ->
        %AST.EscapeExpr{source: "$#{name}"}
    end
  end

  defp lower_path_call_args(path, function, args, %Context{} = context) do
    path
    |> Paths.path_callable_argument_types(function, length(args), context)
    |> lower_args_with_expected(args, context)
  end

  defp lower_call_args(target, function, args, %Context{} = context) do
    target
    |> Paths.callable_argument_types(function, length(args), context)
    |> lower_args_with_expected(args, context)
  end

  defp lower_parent_call_args(function, args, %Context{} = context) do
    Paths.parent_module_callable_argument_types(
      [:Super],
      function,
      length(args),
      context.callables
    )
    |> lower_args_with_expected(args, context)
  end

  defp lower_method_call_args(_receiver_type, _target, :map_get, [key], %Context{} = context),
    do: lower_args_with_expected([rustler_atom_type()], [key], context)

  defp lower_method_call_args(
         %Type{} = receiver_type,
         _target,
         :push,
         [arg],
         %Context{} = context
       ) do
    receiver_type = Type.ref_inner(receiver_type) || receiver_type

    case Type.vec_inner(receiver_type) do
      %Type{} = inner -> lower_args_with_expected([inner], [arg], context)
      nil -> [lower_wrapper_arg_expr(arg, context)]
    end
  end

  # Extending a vector takes items of its type.
  defp lower_method_call_args(%Type{} = receiver_type, _target, :extend, [arg], context) do
    vec_type = Type.ref_inner(receiver_type) || receiver_type

    case Type.vec_inner(vec_type) do
      %Type{} = inner -> lower_args_with_expected([Type.vec(inner)], [arg], context)
      nil -> [lower_expr(arg, context)]
    end
  end

  # Pushing a call that fails as the function does keeps its value, as Elixir would, when the
  # vector's item type is not known yet.
  defp lower_method_call_args(nil, _target, :push, [arg], %Context{} = context),
    do: [lower_wrapper_arg_expr(arg, context)]

  defp lower_method_call_args(
         %Type{} = receiver_type,
         _target,
         :binary_search_by_key,
         [_key_arg, _closure] = args,
         %Context{} = context
       ) do
    case binary_search_by_key_arg_types(receiver_type, args) do
      [_key_type, nil] = expected_types -> lower_args_with_expected(expected_types, args, context)
      nil -> Enum.map(args, &lower_expr(&1, context))
    end
  end

  defp lower_method_call_args(receiver_type, target, function, args, %Context{} = context) do
    arity = length(args)
    expected = Paths.callable_argument_types(target, function, arity, context)
    callable = BindingIndex.get(context.callables, target, function, arity)
    expected = specialize_method_args(callable, receiver_type, args, expected, context)
    lower_args_with_expected(expected, args, context)
  end

  defp specialize_method_args(
         %{target_type: %Type{} = target_type, syn: %{type_parameters: [_ | _] = parameters}},
         %Type{} = receiver_type,
         args,
         expected,
         context
       )
       when is_list(expected) do
    alias RustQ.Binding.Substitution
    actual = Enum.map(args, &infer_expr_type(&1, context.vars))
    pairs = Enum.zip(expected, actual)
    formal_receiver = target_type.ast
    receiver = Type.ref_inner(receiver_type) || receiver_type

    bindings =
      case Substitution.infer(formal_receiver, receiver.ast, parameters) do
        {:ok, bindings} -> bindings
        _ -> %{}
      end

    result =
      Enum.reduce_while(pairs, {:ok, bindings}, fn
        {%Type{} = formal, %Type{} = actual}, {:ok, bindings} ->
          case Substitution.infer(formal.ast, actual.ast, parameters, bindings) do
            {:ok, bindings} -> {:cont, {:ok, bindings}}
            {:error, {:conflict, _, _, _}} = error -> {:halt, error}
            _ -> {:cont, {:ok, bindings}}
          end

        _, result ->
          {:cont, result}
      end)

    case result do
      {:ok, bindings} ->
        Enum.map(expected, &Substitution.apply(&1, bindings))

      {:error, {:conflict, parameter, _, _}} ->
        Diagnostic.lower(
          :conflicting_generic_parameter,
          nil,
          "conflicting types inferred for generic parameter #{parameter}"
        )
    end
  end

  defp specialize_method_args(_callable, _receiver, _args, expected, _context), do: expected

  defp lower_args_with_expected(nil, args, %Context{} = context),
    do: Enum.map(args, &lower_expr(&1, context))

  defp lower_args_with_expected(expected_types, args, %Context{} = context)
       when is_list(expected_types) do
    args
    |> Enum.zip(expected_types)
    |> Enum.map(fn {arg, expected_type} -> lower_expr(arg, expected_type, context) end)
  end

  defp binary_search_by_key_arg_types(%Type{} = receiver_type, [_key_arg, closure]),
    do: Semantics.binary_search_by_key_argument_types(receiver_type, closure)

  defp deref_expected_type(%Type{} = type) do
    if Type.propagates?(type), do: Type.inner(type)
  end

  defp deref_expected_type(_type), do: nil

  defp array_expr?({:array, _, [_values]}), do: true
  defp array_expr?(_expression), do: false

  @doc "Whether `type` is a slice or a reference to one."
  def slice_type?(%Type{kind: :slice}), do: true
  def slice_type?(%Type{ast: %AST.TypeSlice{}}), do: true
  def slice_type?(%Type{ast: %AST.TypeRef{inner: %AST.TypeSlice{}}}), do: true
  def slice_type?(%Type{}), do: false
  def slice_type?(_type), do: false

  # Iterating a borrowed collection with `into_iter` is `iter`.
  defp borrowed_iteration(:into_iter, [], nil), do: :into_iter

  defp borrowed_iteration(:into_iter, [], %Type{} = receiver_type) do
    if slice_type?(receiver_type) or receiver_type.kind in [:ref, :mut_ref],
      do: if(receiver_type.kind == :mut_ref, do: :iter_mut, else: :iter),
      else: :into_iter
  end

  defp borrowed_iteration(function, _args, _receiver_type), do: function

  @doc "The Rust enum variant path an atom of an enum type names."
  # The variant a tagged tuple or atom names, with its payloads and their declared types.
  def rust_enum_variant(pattern, %Type{meta: %{variants: variants}}) do
    {tag, payloads} =
      case pattern do
        tag when is_atom(tag) -> {tag, []}
        {:{}, _, [tag | payloads]} -> {tag, payloads}
        {:enum_variant, _, [_path, tag | payloads]} -> {tag, payloads}
        {tag, payload} -> {tag, [payload]}
        _other -> {nil, []}
      end

    case is_atom(tag) && List.keyfind(variants, tag, 0) do
      {^tag, types} -> {tag, payloads, types}
      _missing -> nil
    end
  end

  defp decode_as_expr(expression, type_ast, %Context{} = context) do
    %AST.MethodCall{
      receiver: lower_decode_receiver(expression, context),
      method: :decode,
      args: [],
      generics: [lower_type_arg(type_ast, context)]
    }
  end

  defp lower_decode_receiver(expression, %Context{} = context) do
    expression
    |> Typing.synth(typing_env(context))
    |> decode_receiver_expected_type()
    |> case do
      %Type{} = expected -> lower_checked_expr(expression, expected, context)
      nil -> lower_expr(expression, rustler_term_type(), context)
    end
  end

  defp decode_receiver_expected_type(%Type{} = type) do
    if Type.propagates?(type), do: Type.inner(type)
  end

  defp decode_receiver_expected_type(_type), do: nil

  defp lower_pipe(left, right, %Context{} = context),
    do: lower_pipe(left, right, nil, context)

  # Piping into a function the module can call passes the value as its first argument, as
  # in Elixir; piping into any other name calls a method on the value.
  defp lower_pipe(left, {name, meta, args}, expected_type, %Context{} = context)
       when is_atom(name) and is_list(args) and name not in [:cast] do
    call =
      if BindingIndex.get(context.callables, nil, name, length(args) + 1),
        do: {name, meta, [left | args]},
        else: {{:., meta, [left, name]}, meta, args}

    if expected_type,
      do: lower_expr(call, expected_type, context),
      else: lower_expr(call, context)
  end

  defp lower_pipe(left, right, expected_type, %Context{} = context) do
    case Call.pipe_remote(left, right) do
      {:ok, call} when is_struct(expected_type, Type) -> lower_expr(call, expected_type, context)
      {:ok, call} -> lower_expr(call, context)
      :unsupported -> lower_pipe_call(lower_expr(left, context), right, context)
    end
  end

  defp lower_pipe_call(receiver, {:cast, _, [type]}, %Context{}),
    do: A.cast(receiver, RustQ.Spec.type(type).ast)

  defp lower_pipe_call(
         receiver,
         {{:., _, [{:__aliases__, _, [:Kernel]}, operator]}, _, [right]},
         %Context{} = context
       )
       when operator in [:+, :-, :*, :/] do
    A.binary(receiver, operator_op(operator), lower_expr(right, context))
  end

  defp lower_pipe_call(receiver, {name, _, args}, %Context{} = context)
       when is_atom(name) and is_list(args) do
    A.method(receiver, name, Enum.map(args, &lower_expr(&1, context)))
  end

  defp lower_pipe_call(_receiver, other, %Context{}) do
    Diagnostic.lower(
      :unsupported_pipeline_step,
      other,
      "unsupported defrust pipeline step",
      suggestion: "Pipe into a method call, cast/1, or add an explicit lowering clause."
    )
  end

  # A closure that only calls a function with its argument is that function, as clippy prefers:
  # `|item| Wrapped(item)` is `Wrapped`.
  defp eta_reduced(%AST.Closure{
         args: [name],
         body: %AST.PathCall{path: path, args: [%AST.Var{name: name}], generics: []},
         move: false
       })
       when is_atom(name),
       do: path

  defp eta_reduced(%AST.Closure{
         args: [name],
         body: %AST.LocalCall{name: function, args: [%AST.Var{name: name}]},
         move: false
       })
       when is_atom(name),
       do: A.path([function])

  defp eta_reduced(closure), do: closure

  # A map's key is read by reference; one already a reference is passed as it is.
  defp borrowed_key(key, %Context{} = context) do
    case infer_expr_type(key, context.vars) || Typing.synth(key, typing_env(context)) do
      %Type{kind: kind} when kind in [:ref, :mut_ref, :slice] -> lower_expr(key, context)
      _owned -> A.ref(lower_expr(key, context))
    end
  end

  defp lower_expected_operand(expression, %Type{} = expected_type, %Context{} = context) do
    if fallible_expression?(expression, context) and propagation_allowed?(context.return_type),
      do: A.try(lower_expr(expression, context)),
      else: lower_expr(expression, expected_type, context)
  end

  defp lower_binary_op(left, op, right, %Context{} = context) do
    A.binary(lower_binary_operand(left, context), op, lower_binary_operand(right, context))
  end

  defp stdlib_context(%Context{} = context, expected \\ nil),
    do: %StdlibContext{env: context, expected: expected}

  @doc "Whether a collection is still in use after this use of it; see `RustQ.Meta.Ownership`."
  # A collection is in use unless this is its value's last use; see `RustQ.Meta.Ownership`. A
  # field reached through a reference is never taken, since the reference does not own it.
  def in_use?(collection, %Context{} = context) do
    indexed_place?(collection) or root_in_use?(collection, context)
  end

  # What indexing reaches stays in its collection, so it is never taken.
  defp indexed_place?({{:., _, [Access, :get]}, _, [_collection, _key]}), do: true

  defp indexed_place?({{:., _, [receiver, _field]}, meta, []}),
    do: meta[:no_parens] == true and indexed_place?(receiver)

  defp indexed_place?(_expression), do: false

  defp root_in_use?(collection, %Context{} = context) do
    case root_variable_node(collection) do
      {name, _meta, _context} = variable ->
        behind_reference?(collection, name, context) or
          Ownership.in_use?(variable, context.built_from, context.vars)

      nil ->
        false
    end
  end

  @doc "`expression`, lowered as an operand: a fallible one propagates its error with `?`."
  def lower_binary_operand(expression, %Context{} = context) do
    if fallible_expression?(expression, context) and propagation_allowed?(context.return_type) do
      A.try(lower_expr(expression, context))
    else
      lower_expr(expression, context)
    end
  end

  defp operator_op(:+), do: :add
  defp operator_op(:-), do: :sub
  defp operator_op(:*), do: :mul
  defp operator_op(:/), do: :div
  defp operator_op(:bsr), do: :shr
  defp operator_op(:band), do: :bitand

  defp lower_expected_closure(args, body, context, expected_type) do
    expected_args = Map.get(expected_type.meta, :args, [])

    context = %{
      closure_context(args, context)
      | return_type: closure_return_type(expected_type),
        scope_return_type: closure_return_type(expected_type),
        position: :expr
    }

    context =
      Enum.zip(args, expected_args)
      |> Enum.reduce(context, fn {pattern, type}, acc ->
        LowerPattern.context_with_match_pattern(pattern, type, acc)
      end)

    A.closure(
      Enum.map(args, &closure_arg!/1),
      lower_closure_body(body, closure_return_type(expected_type), context)
    )
  end

  defp closure_context(args, context) do
    names = Enum.flat_map(args, &LowerPattern.binding_pattern_names/1)

    %{
      context
      | vars: Map.drop(context.vars, names),
        lexical_vars: Map.drop(context.lexical_vars, names)
    }
  end

  @doc "A closure taking `args` and returning `body`, as a value of `expected_return_type` when given."
  def lower_closure_args(args, body, %Context{} = context, expected_return_type \\ nil)
      when is_list(args) do
    {args, typed} = Enum.map_reduce(args, [], &untyped_closure_arg/2)

    captured =
      context.vars
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(context.captured)
      |> MapSet.difference(MapSet.new(Enum.flat_map(args, &LowerPattern.binding_pattern_names/1)))

    context =
      Enum.reduce(typed, closure_context(args, context), fn {arg, type}, context ->
        LowerPattern.context_with_match_pattern(arg, type, context)
      end)

    context = %{context | captured: captured}

    context = %{
      context
      | return_type: expected_return_type,
        scope_return_type: expected_return_type,
        position: :expr
    }

    A.closure(
      Enum.map(args, &closure_arg!/1),
      lower_closure_body(body, expected_return_type, context)
    )
  end

  # A closure argument may carry the type of the items it is given, as an element of the list
  # an `Enum` function or comprehension iterates.
  defp untyped_closure_arg({:__rustq_typed_arg__, _, [arg, %Type{} = type]}, typed),
    do: {arg, [{arg, type} | typed]}

  defp untyped_closure_arg(arg, typed), do: {arg, typed}

  @doc "A closure's `body`, lowered to return a value of `expected_return_type` when given."
  def lower_closure_body(
        {:__block__, _, [_first, _second | _rest] = expressions},
        expected_return_type,
        %Context{} = context
      ) do
    body =
      case expected_return_type do
        %Type{} = type -> lower_expected_block(expressions, context, type)
        _none -> lower_value_block(expressions, context)
      end

    A.block_expr(body)
  end

  def lower_closure_body(body, expected_return_type, %Context{} = context),
    do: lower_expr(closure_body_expr(body), expected_return_type, context)

  defp lower_value_block(expressions, %Context{} = context) do
    context = context_with_downstream_let_types(expressions, context)
    {statements, final} = split_final(expressions)

    Enum.map(statements, &lower_statement(&1, %{context | position: :statement})) ++
      [A.return_stmt(lower_expr(final, %{context | position: :return}))]
  end

  @doc "A captured named function, as the Rust path of that function."
  def lower_function_capture({name, _, capture_context}, %Context{})
      when is_atom(name) and is_atom(capture_context),
      do: A.path([name])

  def lower_function_capture(
        {{:., _, [{:__aliases__, _, [:Super]}, name]}, _, []},
        %Context{}
      ),
      do: A.path([:super, name])

  def lower_function_capture(
        {{:., _, [{:__aliases__, _, parts}, name]}, _, []},
        %Context{} = context
      ),
      do: A.path(Paths.mapped_alias_parts(parts, context.rust_modules) ++ [name])

  def lower_function_capture(other, %Context{}) do
    Diagnostic.lower(
      :unsupported_function_capture,
      other,
      "unsupported function capture in defrust",
      suggestion: "Capture a named local or remote function with arity one."
    )
  end

  @doc "A closure argument, as a Rust closure argument: a name, or a binding pattern."
  def closure_arg!({name, _, context}) when is_atom(name) and is_atom(context), do: name

  def closure_arg!(other), do: LowerPattern.lower_binding_pattern(other)

  defp closure_body_expr([expression]), do: expression
  defp closure_body_expr(expression), do: expression

  defp closure_return_type(%Type{kind: :impl_trait, meta: %{returns: %Type{} = returns}}),
    do: returns

  defp closure_return_type(%Type{kind: :fn, meta: %{returns: %Type{} = returns}}), do: returns

  defp closure_return_type(%Type{ast: %AST.TypeRaw{source: source}}) do
    source
    |> parse_raw_fn_type()
    |> closure_return_type()
  end

  defp closure_return_type(%Type{}), do: nil
  defp closure_return_type(nil), do: nil

  defp parse_raw_fn_type(source) do
    case RustQ.Syn.parse("type __RustQ = #{source};") do
      {:ok, file} ->
        file
        |> RustQ.Syn.type_aliases()
        |> case do
          [%RustQ.Syn.TypeAlias{type_ast: %RustQ.Syn.Type.Fn{} = type_ast}] ->
            Type.from_syn(type_ast)

          _other ->
            nil
        end

      {:error, _errors} ->
        nil
    end
  end

  defp macro_call_name?(name), do: name |> Atom.to_string() |> String.ends_with?("!")

  defp macro_call_part(name) do
    Identifier.atom!(String.trim_trailing(Atom.to_string(name), "!"))
  end

  defp lower_macro_call(name, args, rust_macros, %Context{} = context) do
    part = macro_call_part(name)
    path = A.path([part])

    case Map.get(rust_macros, part) do
      nil ->
        %AST.MacroCall{path: path, args: Enum.map(args, &lower_expr(&1, context))}

      %RustMacro.Definition{} = macro_definition ->
        fragments = RustMacro.fragments(macro_definition)

        if length(args) != length(fragments) do
          Diagnostic.lower(
            :macro_call_arity_mismatch,
            {name, [], args},
            "macro #{part}! expects #{length(fragments)} arguments, got #{length(args)}"
          )
        end

        %AST.TokenMacro{
          path: path,
          tokens:
            args
            |> Enum.zip(fragments)
            |> Enum.map_join(", ", fn {arg, fragment} ->
              macro_call_arg_tokens(arg, fragment, context)
            end)
        }
    end
  end

  defp lower_remote_macro_call(receiver, function, args, %Context{} = context) do
    lower_remote_macro_call(receiver, function, args, context.rust_modules, context)
  end

  defp lower_remote_macro_call(receiver, function, args, rust_modules, %Context{} = context) do
    path_parts =
      cond do
        Paths.super_alias_ast?(receiver) ->
          [:super, macro_call_part(function)]

        Paths.alias_ast?(receiver) ->
          Paths.alias_parts(receiver, rust_modules) ++ [macro_call_part(function)]

        true ->
          nil
      end

    if path_parts do
      %AST.MacroCall{
        path: A.path(path_parts),
        args: Enum.map(args, &lower_expr(&1, context))
      }
    else
      Diagnostic.lower(
        :unsupported_remote_macro_receiver,
        {{:., [], [receiver, function]}, [], args},
        "unsupported remote Rust macro receiver",
        suggestion: "Call Rust macros through an alias path such as Rustler.resource!(...)."
      )
    end
  end

  defp macro_call_arg_tokens(arg, :expr, %Context{} = context),
    do: arg |> lower_expr(context) |> Rust.render()

  defp macro_call_arg_tokens(arg, :ty, %Context{} = context),
    do: arg |> lower_type_arg(context) |> Rust.render_type()

  defp macro_call_arg_tokens(arg, fragment, %Context{} = context)
       when fragment in [:ident, :literal],
       do: arg |> lower_expr(context) |> Rust.render()

  defp macro_call_arg_tokens(arg, fragment, %Context{}) do
    Diagnostic.lower(
      :unsupported_macro_call_fragment,
      arg,
      "unsupported Rust macro fragment #{inspect(fragment)} in defrust macro call",
      suggestion: "Currently RustQ can lower :expr and :ty macro arguments from Rusty-Elixir."
    )
  end

  defp lower_nif_error(atom, %Context{}) when is_atom(atom), do: %AST.NifRaiseAtom{name: atom}
  defp lower_nif_error(other, %Context{} = context), do: lower_expr(other, context)

  defp lower_semantic_arm_body(body, %Context{} = context),
    do: lower_clause_body(body, %{context | position: :return})

  defp lower_type_arg({name, _, ast_context}, %Context{} = context)
       when is_atom(name) and is_atom(ast_context) do
    case macro_var_fragment(name, context.macro_vars) do
      :ty ->
        %AST.TypeRaw{source: "$#{name}"}

      nil ->
        RustQ.Spec.type({name, [], ast_context}).ast

      fragment ->
        Diagnostic.lower(
          :macro_variable_wrong_position,
          {name, [], ast_context},
          "macro variable #{name} is a Rust #{fragment} fragment, but this is a type position"
        )
    end
  end

  defp lower_type_arg(type_ast, %Context{type_aliases: aliases}),
    do: RustQ.Spec.type(type_ast, aliases).ast

  defp rustler_term_type, do: RustQ.Spec.type(quote(do: RustQ.Type.term()))
  defp rustler_atom_type, do: RustQ.Spec.type(quote(do: RustQ.Type.atom()))

  defp parse_syn(type, tokens) do
    A.path_call([:super, "parse_syn::<#{type}>"], [quote_tokens(tokens)])
  end

  defp quote_tokens(tokens) when is_binary(tokens),
    do: %AST.TokenMacro{path: A.path([:quote]), tokens: tokens}

  defp quote_tokens(other) do
    Diagnostic.lower(
      :unsupported_quote_tokens,
      other,
      "unsupported quote tokens",
      suggestion: "Pass a literal binary token string to raw_expr!/raw_pat!/raw_stmt!/raw_arm!."
    )
  end

  defp lower_struct_literal_path({:__aliases__, meta, parts} = alias_ast, %Context{} = context) do
    explicit =
      Enum.find_value(Paths.alias_prefixes(parts), fn {prefix, suffix} ->
        case Map.fetch(context.rust_modules, prefix) do
          {:ok, mapped} -> mapped ++ suffix
          :error -> nil
        end
      end)

    if explicit do
      A.path(explicit)
    else
      type_ast = {{:., meta, [alias_ast, :t]}, meta, []}
      %AST.TypePath{parts: resolved} = RustQ.Spec.type(type_ast, context.type_aliases).ast
      A.path(resolved)
    end
  end

  defp lower_struct_literal_path(path, %Context{} = context), do: lower_expr(path, context)

  @doc "The Rust path of an enum variant written as `enum_variant(Enum, :variant)`."
  def enum_variant_path(path, variant), do: enum_variant_path(path, variant, %Context{})

  def enum_variant_path(path, variant, %Context{} = context) do
    %AST.Path{parts: parts} = lower_expr(path, context)
    A.path(parts ++ [rust_variant(LowerPattern.semantic_atom!(variant))])
  end

  # The struct a type declaration of this module, or of a callable module, names `name`.
  defp declared_struct_type({:__aliases__, _, [name]}, %Context{type_aliases: aliases}) do
    rust_name = Atom.to_string(name)

    Enum.find_value(aliases, fn
      {_key, %Type{kind: :struct, ast: %AST.TypePath{parts: [part]}} = type} ->
        if to_string(part) == rust_name, do: type

      _other ->
        nil
    end)
  end

  defp declared_struct_type(_path, %Context{}), do: nil

  # A closure may run once per item, so a value it captures is copied rather than moved.
  defp clone_captured(lowered, {name, _, ast_context}, %Context{captured: captured})
       when is_atom(name) and is_atom(ast_context) do
    if MapSet.member?(captured, name),
      do: A.method(lowered, :clone),
      else: lowered
  end

  defp clone_captured(lowered, _base, _context), do: lowered

  # `%{value | field: new}` copies the struct with the listed fields replaced.
  defp lower_struct_update(base, fields, %Context{} = context) do
    case infer_expr_type(base, context.vars) || Typing.synth(base, typing_env(context)) do
      %Type{kind: :struct, ast: %AST.TypePath{parts: parts}} = type ->
        %AST.StructLiteral{
          path: A.path(parts),
          fields: lower_named_fields(fields, type, context),
          base: base |> lower_expr(type, context) |> clone_captured(base, context)
        }

      _unknown ->
        Diagnostic.lower(
          :unsupported_struct_update,
          base,
          "struct update needs a value of a known struct type",
          suggestion: "Annotate the value's struct type in the function's @spec."
        )
    end
  end

  defp lower_named_fields(fields, %Context{} = context) when is_list(fields) do
    Enum.map(fields, fn {name, expression} -> {name, lower_expr(expression, context)} end)
  end

  defp lower_named_fields(fields, %Type{} = struct_type, %Context{} = context)
       when is_list(fields) do
    Enum.map(fields, fn {name, expression} ->
      {name, lower_expr(expression, Typing.struct_field_type(struct_type, name), context)}
    end)
  end

  defp lower_token_macro_path(atom) when is_atom(atom), do: A.path([atom])
  defp lower_token_macro_path({:__aliases__, _, parts}), do: A.path(parts)

  defp lower_token_macro_path(other) do
    Diagnostic.lower(
      :unsupported_token_macro_path,
      other,
      "unsupported token_macro path",
      suggestion: "Use an atom or alias as the token macro path."
    )
  end

  defp infer_let_expected_type(pattern, expression, %Context{} = context) do
    Typing.expected_for_let(pattern, expression, typing_env(context))
  end

  @doc "The type of a variable in `vars`, or nil for another expression."
  def infer_expr_type({name, _, context}, vars) when is_atom(name) and is_atom(context),
    do: Map.get(vars, name)

  def infer_expr_type(_expression, _vars), do: nil

  defp context_with_downstream_let_types(expressions, %Context{} = context) do
    inferred =
      Typing.infer_downstream_let_types(
        expressions,
        typing_env(context),
        Map.put(inference_callbacks(context), :block_return_type, context.return_type)
      )

    %{context | vars: Map.merge(context.vars, inferred), lexical_vars: context.vars}
  end

  defp inference_callbacks(%Context{} = context) do
    callables = context.callables

    %{
      return_type: &Paths.callable_return_type(&1, callables: callables, vars: context.vars),
      local_argument_types: fn name, arity ->
        Paths.callable_argument_types(callables, nil, name, arity)
      end,
      path_argument_types: fn parts, function, arity ->
        path = Paths.alias_parts({:__aliases__, [], parts}, context.rust_modules) ++ [function]
        Paths.path_callable_argument_types(path, function, arity, callables, context.rust_modules)
      end,
      method_argument_types: fn target, function, arity ->
        Paths.callable_argument_types(callables, target, function, arity)
      end,
      target_type: &Paths.callable_target_from_type/1,
      method_receiver_type: &method_receiver_type(&1, &2, callables),
      struct_type: &declared_struct_type(&1, context)
    }
  end

  defp method_receiver_type(function, arity, %BindingIndex{} = callables) do
    case BindingIndex.method_targets(callables, function, arity) do
      [target] -> Paths.type_for_callable_target(target)
      _ambiguous_or_missing -> nil
    end
  end

  @doc "The `RustQ.Meta.Typing` environment of a lowering context."
  def typing_env(%Context{} = context) do
    Typing.env(
      type_aliases: context.type_aliases,
      vars: context.vars,
      callables: context.callables,
      rust_modules: context.rust_modules
    )
  end

  @doc "The Rust variant name an Elixir atom names, in Rust case."
  def rust_variant(name), do: Identifier.atom!(Macro.camelize(Atom.to_string(name)))

  defp lower_array_value(
         {:repeat, _, [{group, _, ast_context}, [do: expression]]},
         %Context{} = context
       )
       when is_atom(group) and is_atom(ast_context) do
    repeat_expression(group, expression, context)
  end

  defp lower_array_value(value, %Context{} = context), do: lower_expr(value, context)

  defp repeat_expression(_group, expression, %Context{} = context) do
    %AST.MacroRepeatExpr{expr: lower_expr(expression, context), separator: ",", operator: "*"}
  end

  defp macro_var_fragment(name, macro_vars), do: Map.get(macro_vars, name)
end
