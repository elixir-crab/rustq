defmodule RustQ.Meta.Lower do
  @moduledoc """
  Lowers Rusty-Elixir to RustQ AST: expressions, patterns, control flow, comprehensions, and
  closures, with the borrows, `?` propagation, and wrapping their expected types call for.
  Calls into Elixir's standard library go through `RustQ.Meta.Lower.Stdlib`.
  """

  alias RustQ.Binding.Index, as: BindingIndex
  alias RustQ.Diagnostic
  alias RustQ.Meta.Capture
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.Context, as: StdlibContext
  alias RustQ.Meta.Pattern
  alias RustQ.Meta.RustMacro
  alias RustQ.Meta.Semantics
  alias RustQ.Meta.StandardPointer
  alias RustQ.Meta.StdMethods
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Walk
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
      rust_macros: %{}
    ]
  end

  alias __MODULE__.Env, as: Context

  @spec quoted_body(Macro.t(), Type.t() | nil, map(), keyword()) :: [struct()]
  def quoted_body(body_ast, return_type, vars \\ %{}, opts \\ []) do
    context = %Context{
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
    |> infer_mutability()
  end

  @spec function_body(Macro.t(), Type.t(), map(), keyword()) :: String.t()
  def function_body(body_ast, return_type, vars \\ %{}, opts \\ []) do
    body_ast
    |> quoted_body(return_type, vars, opts)
    |> Enum.map_join("\n", &Rust.render/1)
  end

  @doc """
  Looks up the known return type for a local or remote call AST.

  This is a lowering-time query over the callable metadata supplied through the
  `:callables` option. It is intentionally side-effect-free and does not alter
  lowering yet; type-driven propagation inference will use this lookup to decide
  when a call returning `Result`/`Option`/`NifResult` should lower with Rust `?`.
  """
  @spec callable_return_type(Macro.t(), keyword()) :: Type.t() | nil
  def callable_return_type(call_ast, opts \\ []) do
    callables = opts |> Keyword.get(:callables, []) |> BindingIndex.new()
    rust_modules = Keyword.get(opts, :rust_modules, %{})
    vars = Keyword.get(opts, :vars, %{})

    callable_return_type_from_index(call_ast, callables, rust_modules, vars)
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
      [%AST.Return{expr: lower_expr(final, expected_type, return_context)}]
  end

  @keyed_collections [:HashMap, :HashSet, :BTreeMap, :BTreeSet]
  @iterator_methods StdMethods.iterator()
  @iterator_option_methods StdMethods.iterator_option()
  @mutating_methods StdMethods.mutating()

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
    expected_type = infer_expr_type(target, context.vars)
    lower_assignment(target, expression, expected_type, context)
  end

  defp lower_statement({:return!, _, [expression]}, %Context{return_type: return_type} = context) do
    %AST.EarlyReturn{expr: lower_return_expr(expression, return_type, context)}
  end

  defp lower_statement({:=, _, [pattern, expression]}, %Context{} = context) do
    expected_type = infer_let_expected_type(pattern, expression, context)
    expression_context = context_with_lexical_pattern_vars(pattern, context)

    %AST.Let{
      pattern: lower_binding_pattern(pattern),
      expr:
        expression
        |> lower_expr(expected_type, expression_context)
        |> collect_as(collect_target(expected_type)),
      type: empty_collection_type(expression, expected_type)
    }
  end

  defp lower_statement({:case, _, [expression, [do: clauses]]}, %Context{} = context) do
    case lower_option_if_let_statement(expression, normalize_case_clauses(clauses), context) do
      %AST.IfLet{} = if_let -> if_let
      nil -> %AST.ExprStmt{expr: lower_case(expression, clauses, context)}
    end
  end

  defp lower_statement({:if, _, [condition, branches]}, %Context{} = context) do
    %AST.ExprStmt{expr: lower_if(condition, branches, context)}
  end

  # Run for its effects, a `cond` is a chain of `if`s; a final branch doing nothing is left out.
  defp lower_statement({:cond, _, [[do: clauses]]}, %Context{} = context),
    do: lower_statement(cond_statement(clauses), context)

  defp lower_statement({:with, _, clauses} = with, %Context{} = context) do
    case with_if_lets(clauses) do
      {:ok, matches, body} -> lower_statement(nested_if_lets(matches, body), context)
      :error -> %AST.ExprStmt{expr: lower_with(with |> elem(2), context)}
    end
  end

  defp lower_statement(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Context{} = context
       ) do
    %AST.ExprStmt{expr: lower_statement_expr(expression, context)}
  end

  defp lower_statement({:for, _, args} = expression, %Context{} = context) when is_list(args) do
    case comprehension_parts(expression) do
      {qualifiers, [do: body]} -> lower_for_loop(qualifiers, body, context)
      _other -> %AST.ExprStmt{expr: lower_comprehension(expression, nil, context)}
    end
  end

  defp lower_statement(:ok, %Context{}), do: %AST.ExprStmt{expr: %AST.Tuple{values: []}}

  defp lower_statement({:__block__, _, [expression]}, context),
    do: lower_statement(expression, context)

  defp lower_statement(nil, %Context{}), do: %AST.ExprStmt{expr: %AST.Tuple{values: []}}

  defp lower_statement(expression, %Context{} = context) do
    %AST.ExprStmt{expr: lower_statement_expr(expression, context)}
  end

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
    %AST.Return{expr: lower_case(expression, clauses, context, context.return_type)}
  end

  defp lower_return({:if, _, [condition, branches]}, %Context{} = context) do
    %AST.Return{expr: lower_if(condition, branches, context)}
  end

  defp lower_return({:cond, _, [[do: clauses]]}, %Context{} = context) do
    %AST.Return{expr: lower_cond(clauses, context, context.return_type)}
  end

  defp lower_return({:with, _, clauses}, %Context{} = context) do
    %AST.Return{expr: lower_with(clauses, context)}
  end

  defp lower_return(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Context{} = context
       ) do
    %AST.Return{expr: lower_for_reduce_expr(expression, context)}
  end

  defp lower_return(expression, %Context{return_type: return_type} = context),
    do: %AST.Return{expr: lower_return_expr(expression, return_type, context)}

  defp lower_return_expr(expression, return_type, %Context{} = context),
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

  defp lower_return_expr_context(:ok, _return_type, %Context{}), do: %AST.Tuple{values: []}

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
    %AST.Some{expr: lower_expr(expression, Type.inner(return_type), context)}
  end

  defp lower_return_expr_context(
         {:ok, value},
         %Type{kind: kind} = return_type,
         %Context{} = context
       )
       when kind in [:result, :nif_result],
       do: %AST.Ok{expr: lower_expr(value, Type.inner(return_type) || return_type, context)}

  defp lower_return_expr_context({:error, value}, %Type{kind: :nif_result}, %Context{} = context),
    do: %AST.Err{expr: lower_nif_error(value, context)}

  defp lower_return_expr_context(
         {:error, value},
         %Type{kind: :result} = return_type,
         %Context{} = context
       ),
       do: %AST.Err{expr: lower_expr(value, Type.error(return_type), context)}

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
          else: %AST.Some{expr: lower_expr(expression, context)}
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
      %AST.Try{expr: lower_expr(expression, context)}
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
        %AST.Try{expr: lower_expr(expression, context)}

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
       do: %AST.Ok{expr: atom}

  defp wrap_atom_result(%AST.AtomValue{} = atom, %Type{kind: :nif_result}),
    do: %AST.Ok{expr: atom}

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
        %AST.Ok{expr: lower_expr(expression, Type.inner(return_type), context)}

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

  defp lower_expr(expression, %Context{} = context), do: lower_expr_context(expression, context)

  defp lower_expr(expression, expected_type, %Context{} = context),
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
    do: %AST.Some{expr: lower_expr(value, Type.inner(expected_type), context)}

  defp lower_expected_expr_context(:none, %Type{kind: :option}, %Context{}), do: %AST.None{}

  defp lower_expected_expr_context(
         value,
         %Type{meta: %{elixir_module: String, elixir_type: :t}},
         %Context{}
       )
       when is_binary(value),
       do: %AST.MethodCall{receiver: %AST.Literal{value: value}, method: :to_string, args: []}

  # A borrowed list literal is a borrowed array, which coerces to the slice expected.
  defp lower_expected_expr_context({:ref, _, [values]}, %Type{} = expected_type, context)
       when is_list(values) do
    item_type = Type.slice_inner(Type.expected_value(expected_type))

    %AST.Ref{
      expr: %AST.ArrayLiteral{
        values:
          Enum.map(values, fn value ->
            if item_type,
              do: lower_expr(value, item_type, context),
              else: lower_expr(value, context)
          end)
      }
    }
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

    %AST.Ref{expr: expr}
  end

  defp lower_expected_expr_context(
         {:for, _, [{:<-, _, [_pattern, _expression]}, [reduce: _initial], [do: _clauses]]} =
           expression,
         %Type{} = expected_type,
         %Context{} = context
       ) do
    lower_for_reduce_expr(expression, expected_type, context)
  end

  defp lower_expected_expr_context(
         {:for, _, args} = expression,
         %Type{} = expected_type,
         %Context{} = context
       )
       when is_list(args),
       do: lower_comprehension(expression, expected_type, context)

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

    %AST.PathCall{
      path: %AST.Path{parts: [:ResourceArc, :new]},
      args: [lower_expr(expression, inner, context)]
    }
  end

  defp lower_expected_expr_context(
         {:%, _, [_module, {:%{}, _, fields}]} = expression,
         %Type{kind: :resource} = expected_type,
         %Context{} = context
       )
       when is_list(fields) do
    inner = expected_type |> Type.inner() |> Type.expected_value()

    %AST.PathCall{
      path: %AST.Path{parts: [:ResourceArc, :new]},
      args: [lower_expr(expression, inner, context)]
    }
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
        %AST.Path{parts: [rust_name, rust_variant(variant)]}

      {variant, payloads, types} when length(payloads) == length(types) ->
        %AST.PathCall{
          path: %AST.Path{parts: [rust_name, rust_variant(variant)]},
          args: Enum.zip_with(payloads, types, &lower_expr(&1, &2, context))
        }

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
      %Type{} = inner -> %AST.Ok{expr: lower_expr(value, inner, context)}
      nil -> %AST.Ok{expr: lower_expr(value, context)}
    end
  end

  # `:ok` where nothing is expected is the unit value, as in `ok(:ok)`.
  defp lower_expected_expr_context(:ok, %Type{kind: :unit}, %Context{}),
    do: %AST.Tuple{values: []}

  # An atom where an atom-union enum is expected names its variant.
  defp lower_expected_expr_context(
         atom,
         %Type{kind: :enum, rust: rust_name, meta: %{variants: variants}},
         %Context{} = context
       )
       when is_atom(atom) and atom not in [nil, true, false] and is_list(variants) do
    if atom in variants,
      do: %AST.Path{parts: [rust_name, rust_variant(atom)]},
      else: lower_expr(atom, context)
  end

  defp lower_expected_expr_context(
         {:%{}, _, [{:|, _, [base, fields]}]},
         %Type{} = _expected_type,
         %Context{} = context
       )
       when is_list(fields),
       do: lower_struct_update(base, fields, context)

  defp lower_expected_expr_context(
         {:%{}, _, fields},
         %Type{kind: :struct, ast: %AST.TypePath{parts: parts}} = expected_type,
         %Context{} = context
       )
       when is_list(fields) do
    %AST.StructLiteral{
      path: %AST.Path{parts: parts},
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
      path: %AST.Path{parts: parts},
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

      if expected_type.kind == :nif_result, do: decoded, else: %AST.Try{expr: decoded}
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

    if slice_type?(expected_type), do: %AST.Ref{expr: array}, else: array
  end

  defp lower_expected_expr_context(values, %Type{} = expected_type, %Context{} = context)
       when is_list(values) do
    vec = %AST.VecLiteral{
      values: lower_expected_collection_values(values, expected_type, context)
    }

    if slice_type?(expected_type), do: %AST.Ref{expr: vec}, else: vec
  end

  defp lower_expected_expr_context(
         {:some, _, [expression]},
         %Type{} = expected_type,
         %Context{} = context
       ) do
    case expected_option_inner(expected_type) do
      %Type{} = inner_expected ->
        %AST.Some{expr: lower_option_some_expr(expression, inner_expected, context)}

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

  defp lower_expected_expr_context(
         {{:., _, [receiver = {:__aliases__, _, [module]}, function]}, _, args} = call,
         %Type{} = expected_type,
         %Context{} = context
       )
       when module in [:Kernel, :Enum, :List, :Map, :String, :Tuple, :Range] do
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
        %AST.Ref{expr: expression |> lower_expr(context) |> collect_as(@any_vec)}

      expected_type.kind in [:option, :result] ->
        expression |> lower_expr(context) |> collect_as(expected_type.ast)

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
          |> then(&context_with_match_pattern(arg, Type.inner(receiver_type), &1))
          |> Map.merge(%{
            return_type: closure_return,
            scope_return_type: closure_return,
            position: :expr
          })

        %AST.MethodCall{
          receiver: lower_expr(receiver, context),
          method: method,
          args: [
            %AST.Closure{
              args: [closure_arg!(arg)],
              body: lower_closure_body(body, closure_return, closure_context)
            }
          ]
        }

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
        %AST.MethodCall{receiver: lower_expr(variable, context), method: :to_vec, args: []}

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
      %Type{} = item_type -> Enum.map(values, &lower_expr(&1, item_type, context))
      nil -> Enum.map(values, &lower_array_value(&1, context))
    end
  end

  defp collection_item_type(type) do
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
    %AST.Tuple{
      values:
        values
        |> Enum.zip(types)
        |> Enum.map(fn {value, type} -> lower_expr(value, type, context) end)
    }
  end

  defp lower_expr_context({:unwrap!, _, [expression]}, %Context{} = context),
    do: %AST.Try{expr: lower_expr(expression, context)}

  defp lower_expr_context({:ok_or!, _, [option, error]}, %Context{} = context) do
    %AST.Try{
      expr: %AST.MethodCall{
        receiver: lower_expr(option, context),
        method: :ok_or,
        args: [lower_nif_error(error, context)]
      }
    }
  end

  defp lower_expr_context({:|>, _, [left, right]}, %Context{} = context),
    do: lower_pipe(left, right, context)

  defp lower_expr_context({:cast, _, [expression, type]}, %Context{} = context),
    do: %AST.Cast{
      expr: lower_cast_operand(expression, context),
      type: lower_type_arg(type, context)
    }

  defp lower_expr_context({:decode_as!, _, [expression, type_ast]}, %Context{} = context),
    do: %AST.Try{expr: decode_as_expr(expression, type_ast, context)}

  defp lower_expr_context({:decode_as, _, [expression, type_ast]}, %Context{} = context),
    do: decode_as_expr(expression, type_ast, context)

  # A borrowed list literal is a slice of an array, not of a vector built for the borrow.
  defp lower_expr_context({:ref, _, [values]}, %Context{} = context) when is_list(values),
    do: %AST.Ref{expr: %AST.ArrayLiteral{values: Enum.map(values, &lower_expr(&1, context))}}

  defp lower_expr_context({:ref, _, [expression]}, %Context{} = context),
    do: %AST.Ref{expr: lower_expr(expression, context)}

  defp lower_expr_context({:mut_ref, _, [expression]}, %Context{} = context),
    do: %AST.Ref{expr: lower_expr(expression, context), mutable: true}

  defp lower_expr_context({:deref, _, [expression]}, %Context{} = context) do
    expr =
      expression
      |> Typing.synth(typing_env(context))
      |> deref_expected_type()
      |> case do
        %Type{} = expected -> lower_checked_expr(expression, expected, context)
        nil -> lower_expr(expression, context)
      end

    %AST.UnaryOp{op: :deref, expr: expr}
  end

  defp lower_expr_context({:tuple_field, _, [expression, index]}, %Context{} = context)
       when is_integer(index),
       do: %AST.Field{receiver: lower_expr(expression, context), field: index}

  defp lower_expr_context({:some, _, [expression]}, %Context{} = context),
    do: %AST.Some{expr: lower_some_arg_expr(expression, context)}

  defp lower_expr_context({:none, _, []}, %Context{}), do: %AST.None{}
  defp lower_expr_context({:ok, _, []}, %Context{}), do: %AST.Ok{}

  defp lower_expr_context({:ok, _, [expression]}, %Context{} = context),
    do: %AST.Ok{expr: lower_expr(expression, context)}

  defp lower_expr_context({:err, _, [expression]}, %Context{} = context),
    do: %AST.Err{expr: lower_expr(expression, context)}

  defp lower_expr_context({:token_macro, _, [path, tokens]}, %Context{}),
    do: %AST.TokenMacro{path: lower_token_macro_path(path), tokens: tokens}

  defp lower_expr_context({:move, _, [{:fn, _, [{:->, _, [args, body]}]}]}, %Context{} = context),
    do: %{lower_closure_args(args, body, context) | move: true}

  defp lower_expr_context({:fn, _, [{:->, _, [args, body]}]}, %Context{} = context),
    do: lower_closure_args(args, body, context)

  defp lower_expr_context(
         {{:., _, [receiver = {:__aliases__, _, [module]}, function]}, _, args} = call,
         %Context{} = context
       )
       when module in [:Kernel, :Enum, :List, :Map, :String, :Tuple, :Range] do
    case Stdlib.lower(call, stdlib_context(context)) do
      {:ok, lowered} -> lowered
      :unsupported -> lower_remote_or_method_call(receiver, function, args, context)
    end
  end

  defp lower_expr_context({:expr!, _, [expression]}, %Context{} = context),
    do: lower_expr(expression, context)

  defp lower_expr_context({:pat!, _, [pattern]}, %Context{} = context),
    do: lower_semantic_pat(pattern, context)

  defp lower_expr_context({:stmt!, _, [expression]}, %Context{} = context),
    do: %AST.ExprStmt{expr: lower_expr(expression, context)}

  defp lower_expr_context({:raw_expr!, _, [tokens]}, %Context{}), do: parse_syn(:Expr, tokens)
  defp lower_expr_context({:raw_pat!, _, [tokens]}, %Context{}), do: parse_syn(:Pat, tokens)
  defp lower_expr_context({:raw_stmt!, _, [tokens]}, %Context{}), do: parse_syn(:Stmt, tokens)
  defp lower_expr_context({:raw_arm!, _, [tokens]}, %Context{}), do: parse_syn(:Arm, tokens)

  defp lower_expr_context({:arm!, _, [pattern, block]}, %Context{} = context),
    do: %AST.Arm{
      pattern: lower_semantic_pat(pattern, context),
      body: lower_semantic_arm_body(block, context)
    }

  defp lower_expr_context({:nif_env, _, []}, %Context{}), do: %AST.Path{parts: [:env]}

  defp lower_expr_context({:badarg, _, []}, %Context{}),
    do: %AST.Path{parts: [:rustler, :Error, :BadArg]}

  defp lower_expr_context({:%{}, _, [{:|, _, [base, fields]}]}, %Context{} = context)
       when is_list(fields),
       do: lower_struct_update(base, fields, context)

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
    do: %AST.Index{receiver: lower_expr(receiver, context), index: lower_expr(index, context)}

  # `container[key]` indexes; a map is indexed by a reference to its key.
  defp lower_expr_context({{:., _, [Access, :get]}, _, [receiver, key]}, %Context{} = context) do
    index = lower_expr(key, context)

    index =
      if map_type?(infer_expr_type(receiver, context.vars)),
        do: %AST.Ref{expr: index},
        else: index

    %AST.Index{receiver: lower_expr(receiver, context), index: index}
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
       do: lower_for_reduce_expr(expression, context)

  defp lower_expr_context({:for, _, args} = expression, %Context{} = context)
       when is_list(args),
       do: lower_comprehension(expression, nil, context)

  defp lower_expr_context(
         {{:., _meta, [receiver, field_or_function]}, call_meta, []},
         %Context{} = context
       ) do
    lower_dot_expr(receiver, field_or_function, call_meta, context)
  end

  defp lower_expr_context({{:., _meta, [receiver, function]}, _, args}, %Context{} = context) do
    lower_remote_or_method_call(receiver, function, args, context)
  end

  defp lower_expr_context({:__rustq_path__, _, parts}, %Context{}), do: %AST.Path{parts: parts}

  defp lower_expr_context({:__aliases__, _, parts}, %Context{} = context),
    do: %AST.Path{parts: mapped_alias_parts(parts, context.rust_modules)}

  defp lower_expr_context({:{}, _, values}, %Context{} = context),
    do: %AST.Tuple{values: Enum.map(values, &lower_expr(&1, context))}

  defp lower_expr_context({left, right}, %Context{} = context),
    do: %AST.Tuple{values: [lower_expr(left, context), lower_expr(right, context)]}

  defp lower_expr_context({name, _, args}, %Context{} = context)
       when is_atom(name) and is_list(args) do
    lower_local_or_macro_call(name, args, context)
  end

  defp lower_expr_context({name, _, ast_context}, %Context{} = context)
       when is_atom(name) and is_atom(ast_context) do
    lower_var_or_macro_capture(name, ast_context, context)
  end

  defp lower_expr_context(values, %Context{} = context) when is_list(values),
    do: %AST.VecLiteral{values: Enum.map(values, &lower_array_value(&1, context))}

  defp lower_expr_context(value, %Context{}) when is_binary(value), do: %AST.Literal{value: value}

  defp lower_expr_context(value, %Context{}) when is_integer(value) or is_float(value),
    do: %AST.Literal{value: value}

  defp lower_expr_context(true, %Context{}), do: %AST.Literal{value: true}
  defp lower_expr_context(false, %Context{}), do: %AST.Literal{value: false}
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
    %AST.Try{expr: lower_for_reduce_expr(expression, context)}
  end

  defp lower_statement_expr(expression, %Context{return_type: %Type{} = return_type} = context) do
    if infer_statement_propagation?(expression, return_type, context) do
      %AST.Try{expr: lower_expr(expression, context)}
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
      %AST.Try{expr: lower_expr(expression, context)}
    else
      lower_expr(expression, context)
    end
  end

  defp lower_some_arg_expr(expression, %Context{} = context) do
    if fallible_expression?(expression, context) and propagation_allowed?(context.return_type) do
      %AST.Try{expr: lower_expr(expression, context)}
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
      %AST.Try{expr: lower_expr(expression, context)}
    else
      lower_expr(expression, context)
    end
  end

  defp same_wrapper_propagation?(expression, %Type{} = return_type, %Context{} = context) do
    case callable_return_type(expression,
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
      %AST.Try{expr: lower_expr(expression, context)}
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
    do: %AST.Ref{expr: lower_expr(expression, context)}

  defp lower_checked_coercion(%Typing.Check{coercion: :mut_borrow}, expression, context),
    do: %AST.Ref{expr: lower_expr(expression, context), mutable: true}

  defp lower_checked_coercion(%Typing.Check{coercion: :propagate_borrow}, expression, context),
    do: %AST.Ref{expr: %AST.Try{expr: lower_expr(expression, context)}}

  defp lower_checked_coercion(
         %Typing.Check{coercion: :propagate_mut_borrow},
         expression,
         context
       ),
       do: %AST.Ref{expr: %AST.Try{expr: lower_expr(expression, context)}, mutable: true}

  defp lower_checked_coercion(%Typing.Check{coercion: :as_ref}, expression, context),
    do: option_as_ref_expr(lower_expr(expression, context))

  defp lower_checked_coercion(%Typing.Check{coercion: :propagate_as_ref}, expression, context),
    do: option_as_ref_expr(%AST.Try{expr: lower_expr(expression, context)})

  defp lower_checked_coercion(%Typing.Check{coercion: :deref}, expression, context),
    do: %AST.UnaryOp{op: :deref, expr: lower_expr(expression, context)}

  defp lower_checked_coercion(%Typing.Check{coercion: :some}, expression, context),
    do: %AST.Some{expr: lower_expr(expression, context)}

  defp lower_checked_coercion(%Typing.Check{coercion: :to_vec}, expression, context),
    do: %AST.MethodCall{receiver: lower_expr(expression, context), method: :to_vec, args: []}

  defp lower_checked_coercion(%Typing.Check{}, expression, context),
    do: lower_expr(expression, context)

  defp option_as_ref_expr(expr) do
    %AST.MethodCall{receiver: expr, method: :as_ref, args: []}
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
        {pattern, guard} = split_guarded_pattern(pattern)
        body_context = context_with_match_pattern(pattern, case_type, context)
        body = lower_clause_body(body, body_context, expected_type)
        mutable_vars = body |> collect_pattern_mutations(body_context) |> MapSet.new()

        %AST.Arm{
          pattern:
            pattern
            |> lower_match_pattern(case_type, context)
            |> mark_mutable_pattern_vars(mutable_vars),
          guard: lower_guard_expr(guard, body_context),
          body: body
        }
      end)

    %AST.Match{expr: match_expr, arms: arms}
  end

  defp case_scrutinee(
         expression,
         %Type{kind: :vec} = expression_type,
         clauses,
         %Context{} = context
       ) do
    match_expr = lower_expr(expression, context)

    if Enum.any?(clauses, &list_case_clause?/1) do
      {expression_type, %AST.MethodCall{receiver: match_expr, method: :as_slice, args: []}}
    else
      {expression_type, match_expr}
    end
  end

  defp case_scrutinee(expression, %Type{} = expression_type, clauses, %Context{} = context) do
    if propagate_case_scrutinee?(expression_type, clauses) do
      inner = Type.inner(expression_type)
      {inner, lower_checked_expr(expression, inner, context)}
    else
      {expression_type, lower_expr(expression, context)}
    end
  end

  defp case_scrutinee(expression, _expression_type, clauses, %Context{} = context) do
    {infer_case_type_from_patterns(clauses), lower_expr(expression, context)}
  end

  defp list_case_clause?({:->, _, [[pattern], _body]}) do
    {pattern, _guard} = split_guarded_pattern(pattern)
    list_pattern?(pattern)
  end

  defp propagate_case_scrutinee?(%Type{} = expression_type, clauses) do
    Type.propagates?(expression_type) and not wrapper_case_patterns?(expression_type, clauses)
  end

  defp wrapper_case_patterns?(%Type{kind: kind}, clauses) when kind in [:result, :nif_result] do
    Enum.any?(clauses, fn {:->, _, [[pattern], _body]} ->
      pattern |> split_guarded_pattern() |> elem(0) |> result_pattern?()
    end)
  end

  defp wrapper_case_patterns?(%Type{kind: :option}, clauses) do
    Enum.any?(clauses, fn {:->, _, [[pattern], _body]} ->
      pattern |> split_guarded_pattern() |> elem(0) |> option_pattern?()
    end)
  end

  defp wrapper_case_patterns?(%Type{}, _clauses), do: false

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
      else: [%AST.Return{expr: lower_cond_clauses(rest, context, expected_type)}]
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
      statements -> %AST.BlockExpr{body: statements}
    end
  end

  defp lower_expected_value_block(expressions, %Context{} = context, %Type{} = expected_type) do
    case lower_expected_block(expressions, context, expected_type) do
      [%AST.Return{expr: expr}] -> expr
      statements -> %AST.BlockExpr{body: statements}
    end
  end

  defp lower_condition(condition, %Context{} = context),
    do: lower_binary_operand(condition, context)

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
      callable_return_type(expression,
        callables: context.callables,
        rust_modules: context.rust_modules,
        vars: context.vars
      ) || infer_expr_type(expression, context.vars) ||
        Typing.synth(expression, typing_env(context))

    match_type = declared_case_type(match_type, context)
    body_context = context_with_match_pattern(pattern, match_type, context)

    %AST.Match{
      expr: lower_expr(expression, context),
      arms: [
        %AST.Arm{
          pattern: lower_with_pattern(pattern, match_type, context),
          body: [
            %AST.Return{
              expr: lower_with_matches(rest, body, else_clauses, body_context, expected_type)
            }
          ]
        },
        with_fallback_arm(with_value, pattern, else_clauses, context, expected_type)
      ]
    }
  end

  # A `with` pattern matches what its expression gives; a bare variable binds all of it.
  defp lower_with_pattern({name, _, ast_context} = pattern, _type, %Context{} = context)
       when is_atom(name) and is_atom(ast_context),
       do: lower_match_pattern(pattern, nil, context)

  defp lower_with_pattern(pattern, type, %Context{} = context),
    do: lower_match_pattern(pattern, type, context)

  # Without `else`, an unmatched result or option passes its error or `None` on, as in Elixir.
  defp with_fallback_arm(_value_name, {:ok, _value}, [], _context, _expected_type),
    do:
      passthrough_arm(%AST.PatErr{pattern: %AST.PatVar{name: :error}}, %AST.Err{
        expr: %AST.Var{name: :error}
      })

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
        %AST.Return{expr: lower_with_else(value_name, else_clauses, context, expected_type)}
      ]
    }
  end

  defp passthrough_arm(pattern, expr),
    do: %AST.Arm{pattern: pattern, body: [%AST.Return{expr: expr}]}

  defp lower_with_else(value_name, [], _context, _expected_type), do: %AST.Var{name: value_name}

  defp lower_with_else(value_name, else_clauses, %Context{} = context, expected_type) do
    %AST.Match{
      expr: %AST.Var{name: value_name},
      arms:
        Enum.map(else_clauses, fn {:->, _, [[pattern], body]} ->
          %AST.Arm{
            pattern: lower_match_pattern(pattern, nil, context),
            body: lower_clause_body(body, %{context | position: :return}, expected_type)
          }
        end)
    }
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
    %AST.Assign{
      target: lower_expr(target, context),
      expr: lower_expr(expression, expected_type, context)
    }
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
      %AST.Assign{
        target: lowered_target,
        expr: lower_expr({op, [], [left, right]}, expected_type, context)
      }
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
      then_context = context_with_match_pattern(pattern, case_type, context)
      then_body = lower_clause_body(body, then_context)
      mutable_vars = then_body |> collect_pattern_mutations(then_context) |> MapSet.new()

      %AST.IfLet{
        pattern:
          pattern
          |> lower_match_pattern(case_type, context)
          |> mark_mutable_pattern_vars(mutable_vars),
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
      context = context_with_match_pattern(pattern, type, context)
      body = lower_clause_body(body, context)
      mutable = body |> collect_pattern_mutations(context) |> MapSet.new()

      %AST.IfLet{
        pattern:
          pattern
          |> lower_match_pattern(%Type{kind: :result}, context)
          |> mark_mutable_pattern_vars(mutable),
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
      then_context = context_with_match_pattern(some_pattern, option_type, context)
      then_body = lower_clause_body(some_body, then_context)
      mutable_vars = then_body |> collect_mut_refs() |> MapSet.new()

      %AST.IfLet{
        pattern:
          some_pattern
          |> lower_match_pattern(%Type{kind: :option}, context)
          |> mark_mutable_pattern_vars(mutable_vars),
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

  # A comprehension with any generators, filters, and refutable patterns, lowered through an
  # iterator pipeline: each generator filters and binds in one `filter_map`, its filters as the
  # match guard; later generators nest through `flat_map`, collecting each inner pipeline so
  # its closures never outlive the outer item they borrow.
  defp lower_comprehension(expression, expected_type, %Context{} = context) do
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
      typed_body(Keyword.fetch!(opts, :do), expected_type && collection_item_type(expected_type))

    pipeline =
      quote(
        do:
          unquote(comprehension_pipeline(qualifiers, body, context, {false, []}))
          |> collect()
      )

    case expected_type do
      %Type{} = type ->
        lowered = lower_expr(pipeline, type, context)

        cond do
          slice_type?(type) -> collect_as(lowered, @any_vec)
          context.position == :statement -> collect_as(lowered, type.ast)
          true -> lowered
        end

      nil ->
        pipeline |> lower_expr(context) |> collect_as(@any_vec)
    end
  end

  # A comprehension bound in a statement states what it collects into, since Rust may only
  # learn it from a later borrow; without a collection, it makes a list, as in Elixir.
  defp collect_as(lowered, nil), do: lowered

  defp collect_as(%AST.MethodCall{method: :collect, generics: []} = call, type),
    do: %{call | generics: [type]}

  defp collect_as(lowered, _type), do: lowered

  # Without a known type, a binding collects a list, as Elixir's enumerables do.
  defp collect_target(%Type{ast: ast} = type), do: if(slice_type?(type), do: @any_vec, else: ast)
  defp collect_target(nil), do: @any_vec

  defp comprehension_parts({:for, _, args}) do
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
    reused? = nested? and root != nil and root not in generated
    {stage, binder} = generator_stage(pattern, collection, filters, item_type, reused?)
    bound = context_with_match_pattern(pattern, item_type, context)

    generated = binding_pattern_names(pattern) ++ generated

    binder_type = binder_type(binder, bound)

    case rest do
      [] ->
        comprehension_map(stage, binder, binder_type, body)

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
      case infer_expr_type(collection, context.vars) ||
             Typing.synth(collection, typing_env(context)) do
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
  # item of the earlier ones, so it copies its items rather than consuming it.
  defp generator_stage(pattern, collection, filters, item_type, reused?) do
    items =
      cond do
        iterator_call?(collection) -> collection
        reused? -> quote(do: unquote(collection) |> iter() |> cloned())
        true -> quote(do: unquote(collection) |> into_iter())
      end

    if filters == [] and binding_pattern?(pattern) do
      {items, pattern}
    else
      binder = pattern_binder(pattern)
      {filter_bind(items, guarded_pattern(pattern, filters), binder, item_type), binder}
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

  defp guarded_pattern(pattern, []), do: pattern

  defp guarded_pattern(pattern, filters) do
    guard =
      Enum.reduce(filters, fn filter, guard -> quote(do: unquote(guard) and unquote(filter)) end)

    quote(do: unquote(pattern) when unquote(guard))
  end

  defp binding_pattern?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true

  defp binding_pattern?(pattern) do
    case Pattern.tuple_elements(pattern) do
      elements when is_list(elements) -> Enum.all?(elements, &binding_pattern?/1)
      _not_tuple -> false
    end
  end

  # The variables a pattern binds, as one variable or a tuple of them.
  defp pattern_binder(pattern) do
    case pattern_variables(pattern) do
      [] -> quote(do: {})
      [variable] -> variable
      variables -> {:{}, [], variables}
    end
  end

  defp pattern_variables(pattern) do
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

  # A comprehension evaluated for its effects: nested loops, `if let` for patterns that can fail,
  # and `if` for filters, so the body may return early.
  defp lower_for_loop([{:<-, _, [pattern, collection]} | rest], body, %Context{} = context) do
    body_context = context_with_for_pattern(pattern, collection, context)

    if binding_pattern?(pattern) do
      %AST.For{
        pattern: lower_binding_pattern(pattern),
        expr: lower_expr(collection, context),
        body: lower_for_loop_body(rest, body, body_context)
      }
    else
      %AST.For{
        pattern: %AST.PatVar{name: :__rustq_item},
        expr: lower_expr(collection, context),
        body: [
          %AST.IfLet{
            pattern: lower_match_pattern(pattern, nil, context),
            expr: %AST.Var{name: :__rustq_item},
            then:
              lower_for_loop_body(rest, body, context_with_match_pattern(pattern, nil, context))
          }
        ]
      }
    end
  end

  defp lower_for_loop_body([], body, %Context{} = context), do: lower_clause_body(body, context)

  defp lower_for_loop_body([{:<-, _, _} | _] = qualifiers, body, %Context{} = context),
    do: [lower_for_loop(qualifiers, body, context)]

  defp lower_for_loop_body([filter | rest], body, %Context{} = context) do
    [
      %AST.ExprStmt{
        expr: %AST.If{
          condition: lower_expr(filter, context),
          then: lower_for_loop_body(rest, body, context)
        }
      }
    ]
  end

  defp lower_for_reduce_expr(expression, %Context{return_type: %Type{} = return_type} = context),
    do: lower_for_reduce_expr(expression, return_type, context)

  defp lower_for_reduce_expr(
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
          pattern: lower_binding_pattern(pattern),
          expr: lower_expr(expression, context),
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

  defp lower_for_reduce_expr(other, _return_type, _context) do
    Diagnostic.lower(
      :unsupported_for_reduce,
      other,
      "unsupported defrust for/reduce expression",
      suggestion: "Use `for pattern <- enumerable, reduce: initial do acc_pattern -> body end`."
    )
  end

  defp lower_reduce_initial(initial, %Type{} = acc_type, %Context{} = context) do
    if Type.propagates?(acc_type) do
      lower_return_expr(initial, acc_type, context)
    else
      lower_expr(initial, acc_type, context)
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
      body_context = context_with_match_pattern(pattern, return_type, context)

      %AST.Arm{
        pattern: lower_match_pattern(pattern, return_type, context),
        body:
          lower_clause_body(
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

  defp block_expr([%AST.Return{expr: expr}]), do: expr

  defp block_expr(statements) do
    %AST.BlockExpr{body: statements}
  end

  defp lower_clause_body(body, %Context{position: :statement} = context) do
    expressions = block_expressions(body)
    context = context_with_downstream_let_types(expressions, context)

    expressions
    |> Enum.map(&lower_statement(&1, context))
    |> reject_unit_statements()
  end

  defp lower_clause_body(body, %Context{position: :return} = context) do
    body
    |> block_expressions()
    |> lower_block(context)
  end

  defp lower_clause_body(body, %Context{position: :expr} = context) do
    body
    |> block_expressions()
    |> lower_block(%{context | return_type: nil})
  end

  defp lower_clause_body(body, %Context{position: :expr} = context, %Type{} = expected_type) do
    body
    |> block_expressions()
    |> lower_expected_block(%{context | return_type: expected_type}, expected_type)
  end

  defp lower_clause_body(body, %Context{position: :return} = context, %Type{} = expected_type) do
    if Type.propagates?(expected_type) do
      lower_clause_body(body, context)
    else
      body
      |> block_expressions()
      |> lower_expected_block(%{context | return_type: expected_type}, expected_type)
    end
  end

  defp lower_clause_body(body, %Context{} = context, _expected_type),
    do: lower_clause_body(body, context)

  defp infer_case_type_from_patterns(clauses) do
    if Enum.any?(clauses, fn {:->, _, [[pattern], _body]} -> option_pattern?(pattern) end) do
      %Type{kind: :option}
    end
  end

  defp option_pattern?(nil), do: true
  defp option_pattern?(:none), do: true
  defp option_pattern?({:some, _pattern}), do: true
  defp option_pattern?({:{}, _, [:some, _pattern]}), do: true
  defp option_pattern?(_pattern), do: false

  defp list_pattern?([]), do: true
  defp list_pattern?([_head | _tail]), do: true
  defp list_pattern?(_pattern), do: false

  defp split_list_pattern(pattern), do: do_split_list_pattern(pattern, [])

  defp do_split_list_pattern([], elements), do: {Enum.reverse(elements), nil}

  defp do_split_list_pattern([{:|, _, [head, rest]}], elements),
    do: {Enum.reverse([head | elements]), rest}

  defp do_split_list_pattern([head | tail], elements) when is_list(tail),
    do: do_split_list_pattern(tail, [head | elements])

  defp do_split_list_pattern([head | tail], elements),
    do: {Enum.reverse([head | elements]), tail}

  defp result_pattern?({:ok, _pattern}), do: true
  defp result_pattern?({:error, _pattern}), do: true
  defp result_pattern?({:{}, _, [:ok, _pattern]}), do: true
  defp result_pattern?({:{}, _, [:error, _pattern]}), do: true
  defp result_pattern?(ok: _pattern), do: true
  defp result_pattern?(error: _pattern), do: true
  defp result_pattern?(_pattern), do: false

  defp reject_unit_statements(statements) do
    Enum.reject(statements, fn
      %AST.ExprStmt{expr: %AST.Tuple{values: []}} -> true
      _other -> false
    end)
  end

  defp lower_binding_pattern({name, _, context}) when is_atom(name) and is_atom(context),
    do: %AST.PatVar{name: name}

  defp lower_binding_pattern({:{}, _, values}),
    do: %AST.PatTuple{patterns: Enum.map(values, &lower_binding_pattern/1)}

  defp lower_binding_pattern({left, right}),
    do: %AST.PatTuple{patterns: Enum.map([left, right], &lower_binding_pattern/1)}

  defp lower_binding_pattern(other) do
    Diagnostic.lower(
      :unsupported_binding_pattern,
      other,
      "unsupported defrust binding pattern",
      suggestion: "Use a variable or tuple pattern."
    )
  end

  defp split_guarded_pattern({:when, _, [pattern, guard]}), do: {pattern, guard}
  defp split_guarded_pattern(pattern), do: {pattern, nil}

  defp context_with_match_pattern(pattern, %Type{kind: :option} = type, %Context{} = context) do
    context_with_inner_pattern(pattern, Type.inner(type), [:some], context)
  end

  defp context_with_match_pattern(pattern, %Type{kind: kind} = type, %Context{} = context)
       when kind in [:result, :nif_result] do
    context_with_inner_pattern(pattern, Type.inner(type), [:ok], context)
  end

  defp context_with_match_pattern([], %Type{kind: :vec} = type, %Context{} = context),
    do: context_with_list_pattern([], type, context)

  defp context_with_match_pattern(pattern, %Type{} = type, %Context{} = context)
       when is_list(pattern) and type.kind == :slice,
       do: context_with_list_pattern(pattern, type, context)

  defp context_with_match_pattern(
         [_head | _tail] = pattern,
         %Type{kind: :vec} = type,
         %Context{} = context
       ),
       do: context_with_list_pattern(pattern, type, context)

  defp context_with_match_pattern(
         {:%{}, _, fields},
         %Type{kind: :struct} = type,
         %Context{} = context
       )
       when is_list(fields),
       do: context_with_struct_pattern(fields, type, context)

  defp context_with_match_pattern(
         {:%, _, [_module, {:%{}, _, fields}]},
         %Type{kind: :struct} = type,
         %Context{} = context
       )
       when is_list(fields),
       do: context_with_struct_pattern(fields, type, context)

  defp context_with_match_pattern(
         {name, _meta, ast_context},
         %Type{} = type,
         %Context{} = context
       )
       when is_atom(name) and is_atom(ast_context) do
    %{context | vars: Map.put(context.vars, name, type)}
  end

  defp context_with_match_pattern(pattern, %Type{kind: :rust_enum} = type, %Context{} = context),
    do: context_with_variant_pattern(pattern, type, & &1, context)

  defp context_with_match_pattern(
         pattern,
         %Type{kind: kind, meta: %{inner: %Type{kind: :rust_enum} = inner}},
         %Context{} = context
       )
       when kind in [:ref, :mut_ref],
       do: context_with_variant_pattern(pattern, inner, &Type.ref/1, context)

  defp context_with_match_pattern(pattern, %Type{kind: :tuple, meta: %{elements: types}}, context) do
    case Pattern.tuple_elements(pattern) do
      elements when is_list(elements) and length(elements) == length(types) ->
        elements
        |> Enum.zip(types)
        |> Enum.reduce(context, fn {element, type}, acc ->
          context_with_match_pattern(element, type, acc)
        end)

      _not_tuple ->
        context
    end
  end

  # A pattern of unknown type still shadows the names it binds; they lose their old types.
  defp context_with_match_pattern(pattern, _type, %Context{} = context) do
    names = pattern |> pattern_variables() |> Enum.map(&elem(&1, 0))
    %{context | vars: Map.drop(context.vars, names)}
  end

  defp context_with_variant_pattern(pattern, type, payload_type, %Context{} = context) do
    case rust_enum_variant(pattern, type) do
      {_variant, payloads, types} when length(payloads) == length(types) ->
        payloads
        |> Enum.zip(types)
        |> Enum.reduce(context, fn {payload, type}, acc ->
          context_with_match_pattern(payload, payload_type.(type), acc)
        end)

      _other ->
        context
    end
  end

  defp context_with_struct_pattern(fields, %Type{} = type, %Context{} = context) do
    Enum.reduce(fields, context, fn {field, pattern}, acc ->
      case Type.field_type(type, field) do
        %Type{} = field_type -> context_with_match_pattern(pattern, field_type, acc)
        nil -> acc
      end
    end)
  end

  # A slice binds its elements by reference; a vector matched as a slice does too.
  defp context_with_list_pattern(pattern, %Type{} = type, %Context{} = context) do
    {elements, rest} = split_list_pattern(pattern)
    inner = list_item_type(type)
    inner = if inner && type.kind == :slice, do: Type.ref(inner), else: inner

    context =
      Enum.reduce(elements, context, fn element, acc ->
        context_with_match_pattern(element, inner, acc)
      end)

    if rest,
      do: context_with_match_pattern(rest, Type.slice_ref(inner), context),
      else: context
  end

  defp context_with_for_pattern(pattern, expression, %Context{} = context) do
    expression
    |> infer_expr_type(context.vars)
    |> Kernel.||(Typing.synth(expression, typing_env(context)))
    |> for_item_type()
    |> case do
      %Type{} = item_type -> context_with_match_pattern(pattern, item_type, context)
      nil -> context
    end
  end

  defp for_item_type(%Type{} = type), do: Type.vec_inner(type) || Type.slice_inner(type)
  defp for_item_type(_type), do: nil

  defp context_with_inner_pattern(pattern, %Type{} = inner, wrappers, %Context{} = context) do
    case unwrap_match_pattern(pattern, wrappers) do
      nil -> context
      inner_pattern -> context_with_match_pattern(inner_pattern, inner, context)
    end
  end

  defp context_with_inner_pattern(_pattern, _inner, _wrappers, %Context{} = context), do: context

  defp unwrap_match_pattern({name, _meta, ast_context} = pattern, _wrappers)
       when is_atom(name) and is_atom(ast_context),
       do: pattern

  defp unwrap_match_pattern({wrapper, inner}, wrappers) do
    if wrapper in wrappers, do: inner
  end

  defp unwrap_match_pattern({:{}, _, [wrapper, inner]}, wrappers) do
    if wrapper in wrappers, do: inner
  end

  defp unwrap_match_pattern(_pattern, _wrappers), do: nil

  defp lower_guard_expr(nil, %Context{}), do: nil
  defp lower_guard_expr(guard, %Context{} = context), do: lower_expr(guard, context)

  # Patterns name constants and enum variants through the module's Rust module aliases.
  defp lower_match_pattern(pattern, case_type, %Context{} = context),
    do: pattern |> resolve_pattern_paths(context) |> lower_match_pattern(case_type)

  defp resolve_pattern_paths(pattern, %Context{} = context) do
    Macro.prewalk(pattern, fn
      {:enum_variant, meta, [{:__aliases__, _, parts} | rest]} ->
        {:enum_variant, meta, [rust_path_marker(parts, context) | rest]}

      {:__aliases__, _, parts} = alias ->
        if constant_alias?(parts), do: rust_path_marker(parts, context), else: alias

      other ->
        other
    end)
  end

  defp rust_path_marker(parts, %Context{} = context),
    do: {:__rustq_path__, [], mapped_alias_parts(parts, context.rust_modules)}

  # A constant ends in an upper-case segment such as `Kind.PLAIN`.
  defp constant_alias?(parts) do
    name = parts |> List.last() |> Atom.to_string()
    name == String.upcase(name) and String.length(name) > 1
  end

  defp lower_match_pattern({:__rustq_path__, _, parts}, _case_type),
    do: %AST.PatPath{path: %AST.Path{parts: parts}}

  defp lower_match_pattern(:ok, %Type{kind: kind}) when kind in [:result, :nif_result],
    do: %AST.PatOk{pattern: %AST.PatTuple{patterns: []}}

  defp lower_match_pattern(nil, %Type{kind: :option}), do: %AST.PatNone{}
  defp lower_match_pattern(:none, %Type{kind: :option}), do: %AST.PatNone{}
  defp lower_match_pattern(nil, _case_type), do: %AST.PatNone{}
  defp lower_match_pattern(:none, _case_type), do: %AST.PatNone{}
  defp lower_match_pattern({:_, _, _}, _case_type), do: %AST.PatWildcard{}

  defp lower_match_pattern(value, _case_type)
       when is_binary(value) or is_integer(value) or is_boolean(value),
       do: %AST.PatLiteral{value: value}

  defp lower_match_pattern([ok: pattern], _case_type),
    do: %AST.PatOk{pattern: lower_match_pattern(pattern, nil)}

  defp lower_match_pattern([error: pattern], _case_type),
    do: %AST.PatErr{pattern: lower_match_pattern(pattern, nil)}

  defp lower_match_pattern({:ok, pattern}, _case_type),
    do: %AST.PatOk{pattern: lower_match_pattern(pattern, nil)}

  defp lower_match_pattern({:error, pattern}, _case_type),
    do: %AST.PatErr{pattern: lower_match_pattern(pattern, nil)}

  defp lower_match_pattern({:some, pattern}, %Type{kind: :option} = type),
    do: %AST.PatSome{pattern: lower_tuple_element_pattern(pattern, Type.inner(type))}

  defp lower_match_pattern({:some, pattern}, _case_type),
    do: %AST.PatSome{pattern: lower_match_pattern(pattern, nil)}

  defp lower_match_pattern({:{}, _, [:some, pattern]}, %Type{kind: :option} = type),
    do: %AST.PatSome{pattern: lower_tuple_element_pattern(pattern, Type.inner(type))}

  defp lower_match_pattern({:{}, _, [:some, pattern]}, _case_type),
    do: %AST.PatSome{pattern: lower_match_pattern(pattern, nil)}

  defp lower_match_pattern({:enum_variant, _, [path, variant]}, _case_type) do
    %AST.PatPath{path: enum_variant_path(path, variant)}
  end

  defp lower_match_pattern({:enum_variant, _, [path, variant | patterns]}, _case_type) do
    %AST.PatPathTuple{
      path: enum_variant_path(path, variant),
      patterns: Enum.map(patterns, &lower_match_pattern(&1, nil))
    }
  end

  defp lower_match_pattern([], %Type{kind: :vec} = type), do: lower_list_pattern([], type)

  defp lower_match_pattern(pattern, %Type{kind: :slice} = type) when is_list(pattern),
    do: lower_list_pattern(pattern, type)

  # A list pattern on a value of unknown type matches it as a slice.
  defp lower_match_pattern(pattern, nil)
       when is_list(pattern) and pattern != [] and not is_tuple(hd(pattern)),
       do: lower_list_pattern(pattern, nil)

  defp lower_match_pattern([_head | _tail] = pattern, %Type{kind: :vec} = type),
    do: lower_list_pattern(pattern, type)

  defp lower_match_pattern(
         {:%{}, _, fields},
         %Type{kind: :struct, rust: rust_name, meta: %{fields: type_fields}}
       )
       when is_list(fields) do
    %AST.PatStruct{
      path: %AST.Path{parts: [rust_name]},
      fields: lower_struct_pattern_fields(fields, type_fields)
    }
  end

  defp lower_match_pattern(
         {:%, _, [_module, {:%{}, _, fields}]},
         %Type{kind: :struct, rust: rust_name, meta: %{fields: type_fields}}
       )
       when is_list(fields) do
    %AST.PatStruct{
      path: %AST.Path{parts: [rust_name]},
      fields: lower_struct_pattern_fields(fields, type_fields)
    }
  end

  defp lower_match_pattern({:%, _, [{:__aliases__, _, modules}, {:%{}, _, fields}]}, %Type{
         kind: :tuple_enum,
         rust: rust_name
       }) do
    module = List.last(modules)

    %AST.PatPathTuple{
      path: %AST.Path{parts: [rust_name, module]},
      patterns: [
        %AST.PatStruct{
          path: %AST.Path{parts: [module]},
          fields:
            Enum.map(fields, fn {name, pattern} -> {name, lower_match_pattern(pattern, nil)} end)
        }
      ]
    }
  end

  defp lower_match_pattern({name, _, context}, %Type{kind: :option})
       when is_atom(name) and is_atom(context),
       do: %AST.PatSome{pattern: %AST.PatVar{name: name}}

  defp lower_match_pattern({name, _, context}, _case_type)
       when is_atom(name) and is_atom(context),
       do: %AST.PatVar{name: name}

  # A borrowed enum matches its variants as they are, binding payloads by reference.
  defp lower_match_pattern(
         pattern,
         %Type{kind: kind, meta: %{inner: %Type{kind: :rust_enum} = inner}}
       )
       when kind in [:ref, :mut_ref] and (is_atom(pattern) or is_tuple(pattern)),
       do: lower_match_pattern(pattern, inner)

  defp lower_match_pattern(pattern, %Type{kind: :rust_enum, rust: rust_name} = type)
       when is_atom(pattern) or is_tuple(pattern) do
    case rust_enum_variant(pattern, type) do
      {variant, [], _types} ->
        %AST.PatPath{path: %AST.Path{parts: [rust_name, rust_variant(variant)]}}

      {variant, payloads, types} when length(payloads) == length(types) ->
        %AST.PatPathTuple{
          path: %AST.Path{parts: [rust_name, rust_variant(variant)]},
          patterns: Enum.zip_with(payloads, types, &lower_tuple_element_pattern/2)
        }

      _other ->
        lower_match_pattern(pattern, nil)
    end
  end

  defp lower_match_pattern(atom, %Type{kind: :enum, rust: rust_name}) when is_atom(atom),
    do: %AST.PatPath{path: %AST.Path{parts: [rust_name, rust_variant(atom)]}}

  defp lower_match_pattern(atom, %Type{kind: :atom}) when is_atom(atom),
    do: %AST.PatAtomGuard{name: atom}

  defp lower_match_pattern(atom, _case_type) when is_atom(atom), do: %AST.PatAtomGuard{name: atom}

  defp lower_match_pattern({:{}, _, values}, case_type),
    do: lower_tuple_match_pattern(values, case_type)

  defp lower_match_pattern({left, right}, case_type),
    do: lower_tuple_match_pattern([left, right], case_type)

  defp lower_match_pattern(other, _case_type) do
    Diagnostic.lower(
      :unsupported_match_pattern,
      other,
      "unsupported defrust match pattern",
      suggestion:
        "Use a variable, tuple, list, option/result, atom, literal, or supported struct pattern."
    )
  end

  defp lower_struct_pattern_fields(fields, type_fields) do
    patterns = Map.new(fields)

    Enum.map(type_fields, fn {name, _type, _presence} ->
      pattern = Map.get(patterns, name, {:_, [], nil})
      {name, lower_match_pattern(pattern, nil)}
    end)
  end

  defp lower_list_pattern(pattern, type) do
    {elements, rest} = split_list_pattern(pattern)
    inner = type && list_item_type(type)

    %AST.PatSlice{
      patterns: Enum.map(elements, &lower_tuple_element_pattern(&1, inner)),
      rest: if(rest, do: lower_match_pattern(rest, inner && Type.slice_ref(inner)))
    }
  end

  defp list_item_type(%Type{} = type), do: Type.vec_inner(type) || Type.slice_inner(type)

  # Each element is a pattern of its own, such as `{:some, Kind.PLAIN}`.
  defp lower_tuple_match_pattern(values, case_type) do
    types =
      case case_type && Type.expected_value(case_type) do
        %Type{kind: :tuple, meta: %{elements: elements}}
        when length(elements) == length(values) ->
          elements

        _unknown ->
          List.duplicate(nil, length(values))
      end

    %AST.PatTuple{patterns: Enum.zip_with(values, types, &lower_tuple_element_pattern/2)}
  end

  # A variable binds the whole element, whatever its type.
  defp lower_tuple_element_pattern({name, _, context} = pattern, _type)
       when is_atom(name) and is_atom(context),
       do: lower_match_pattern(pattern, nil)

  defp lower_tuple_element_pattern(pattern, type), do: lower_match_pattern(pattern, type)

  defp mark_mutable_pattern_vars(%AST.PatVar{name: name} = pattern, mutable_vars) do
    if MapSet.member?(mutable_vars, name), do: %{pattern | mutable: true}, else: pattern
  end

  defp mark_mutable_pattern_vars(%AST.PatSome{pattern: pattern} = some, mutable_vars),
    do: %{some | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

  defp mark_mutable_pattern_vars(%AST.PatOk{pattern: pattern} = ok, mutable_vars),
    do: %{ok | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

  defp mark_mutable_pattern_vars(%AST.PatErr{pattern: pattern} = err, mutable_vars),
    do: %{err | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

  defp mark_mutable_pattern_vars(%AST.PatTuple{patterns: patterns} = tuple, mutable_vars),
    do: %{tuple | patterns: Enum.map(patterns, &mark_mutable_pattern_vars(&1, mutable_vars))}

  defp mark_mutable_pattern_vars(%AST.PatPathTuple{patterns: patterns} = tuple, mutable_vars),
    do: %{tuple | patterns: Enum.map(patterns, &mark_mutable_pattern_vars(&1, mutable_vars))}

  defp mark_mutable_pattern_vars(%AST.PatStruct{fields: fields} = struct, mutable_vars) do
    fields =
      Enum.map(fields, fn {name, pattern} ->
        {name, mark_mutable_pattern_vars(pattern, mutable_vars)}
      end)

    %{struct | fields: fields}
  end

  defp mark_mutable_pattern_vars(pattern, _mutable_vars), do: pattern

  defp lower_dot_expr(receiver, field_or_function, call_meta, %Context{} = context) do
    no_parens? = Keyword.get(call_meta, :no_parens, false)

    cond do
      no_parens? and alias_path_ast?(receiver) ->
        %AST.Path{parts: alias_path_parts(receiver, context.rust_modules) ++ [field_or_function]}

      no_parens? ->
        %AST.Field{receiver: lower_expr(receiver, context), field: field_or_function}

      super_alias_ast?(receiver) ->
        %AST.PathCall{path: %AST.Path{parts: [:super, field_or_function]}, args: []}

      alias_ast?(receiver) ->
        %AST.PathCall{
          path: %AST.Path{
            parts: alias_parts(receiver, context.rust_modules) ++ [field_or_function]
          },
          args: []
        }

      field_or_function == :into_iter ->
        receiver_type =
          infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))

        %AST.MethodCall{
          receiver: lower_dot_receiver(receiver, :into_iter, context),
          method: borrowed_iteration(:into_iter, [], receiver_type)
        }

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
       do: %AST.Try{expr: lower_expr(receiver, context)}

  defp lower_dot_receiver(receiver, _method, %Context{} = context),
    do: lower_expr(receiver, context)

  defp lower_remote_or_method_call(receiver, function, args, %Context{} = context) do
    cond do
      macro_call_name?(function) ->
        lower_remote_macro_call(receiver, function, args, context)

      super_alias_ast?(receiver) ->
        %AST.PathCall{
          path: %AST.Path{parts: [:super, function]},
          args: lower_parent_call_args(function, args, context)
        }

      rust_constructor_alias?(receiver) ->
        path = alias_parts(receiver, context.rust_modules) ++ [rust_variant(function)]

        %AST.PathCall{
          path: %AST.Path{parts: path},
          args: lower_path_call_args(path, function, args, context)
        }

      alias_ast?(receiver) ->
        path = alias_parts(receiver, context.rust_modules) ++ [function]

        %AST.PathCall{
          path: %AST.Path{parts: path},
          args: lower_path_call_args(path, function, args, context)
        }

      true ->
        receiver_type =
          infer_expr_type(receiver, context.vars) || Typing.synth(receiver, typing_env(context))

        target = callable_target_from_type(receiver_type)

        %AST.MethodCall{
          receiver: lower_method_receiver(receiver, receiver_type, function, context),
          method: borrowed_iteration(function, args, receiver_type),
          args: lower_method_call_args(receiver_type, target, function, args, context)
        }
    end
  end

  defp lower_method_receiver(
         {{:., _, [_term, :map_get]}, _, [_key]} = receiver,
         _receiver_type,
         _function,
         %Context{} = context
       ) do
    %AST.Try{expr: lower_expr(receiver, context)}
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

  defp lower_method_receiver(receiver, _receiver_type, _function, %Context{} = context),
    do: lower_expr(receiver, context)

  defp lower_local_or_macro_call(name, args, %Context{} = context) do
    if macro_call_name?(name) do
      lower_macro_call(name, args, context.rust_macros, context)
    else
      %AST.LocalCall{name: name, args: lower_call_args(nil, name, args, context)}
    end
  end

  defp lower_var_or_macro_capture(name, ast_context, %Context{} = context) do
    case macro_var_fragment(name, context.macro_vars) do
      nil ->
        %AST.Var{name: name}

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
    |> path_callable_argument_types(function, length(args), context)
    |> lower_args_with_expected(args, context)
  end

  defp lower_call_args(target, function, args, %Context{} = context) do
    target
    |> callable_argument_types(function, length(args), context)
    |> lower_args_with_expected(args, context)
  end

  defp lower_parent_call_args(function, args, %Context{} = context) do
    parent_module_callable_argument_types([:Super], function, length(args), context.callables)
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
    expected = callable_argument_types(target, function, arity, context)
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

  defp slice_type?(%Type{kind: :slice}), do: true
  defp slice_type?(%Type{ast: %AST.TypeSlice{}}), do: true
  defp slice_type?(%Type{ast: %AST.TypeRef{inner: %AST.TypeSlice{}}}), do: true
  defp slice_type?(%Type{}), do: false
  defp slice_type?(_type), do: false

  defp callable_argument_types(target, function, arity, %Context{callables: callables}) do
    callable_argument_types(callables, target, function, arity)
  end

  defp callable_argument_types(%BindingIndex{} = callables, target, function, arity) do
    BindingIndex.argument_types(callables, target, function, arity)
  end

  defp path_callable_argument_types(path, function, arity, %Context{} = context) do
    path_callable_argument_types(path, function, arity, context.callables, context.rust_modules)
  end

  defp path_callable_argument_types(
         path,
         function,
         arity,
         %BindingIndex{} = callables,
         rust_modules
       ) do
    target_parts = Enum.drop(path, -1)

    parent_module_callable_argument_types(target_parts, function, arity, callables) ||
      target_parts
      |> exact_callable_target_candidates(rust_modules)
      |> Enum.find_value(&callable_argument_types(callables, &1, function, arity)) ||
      path_module_fallback_argument_types(target_parts, function, arity, callables) ||
      target_parts
      |> callable_target_candidates(rust_modules)
      |> Enum.find_value(&callable_argument_types(callables, &1, function, arity))
  end

  defp parent_module_callable_argument_types(
         [:Super],
         function,
         arity,
         %BindingIndex{} = callables
       ),
       do:
         callable_argument_types(callables, nil, function, arity) ||
           BindingIndex.unqualified_argument_types(callables, function, arity)

  defp parent_module_callable_argument_types(_target_parts, _function, _arity, %BindingIndex{}),
    do: nil

  defp path_module_fallback_argument_types(
         target_parts,
         function,
         arity,
         %BindingIndex{} = callables
       ) do
    if rust_module_path?(target_parts) do
      callable_argument_types(callables, nil, function, arity)
    end
  end

  defp parent_module_callable_return_type([:Super], function, arity, %BindingIndex{} = callables),
    do:
      BindingIndex.return_type(callables, nil, function, arity) ||
        BindingIndex.unqualified_return_type(callables, function, arity)

  defp parent_module_callable_return_type(_target_parts, _function, _arity, %BindingIndex{}),
    do: nil

  defp path_module_fallback_return_type(
         target_parts,
         function,
         arity,
         %BindingIndex{} = callables
       ) do
    if rust_module_path?(target_parts) do
      BindingIndex.return_type(callables, nil, function, arity)
    end
  end

  defp rust_module_path?([_ | _] = parts),
    do: rust_module_name?(parts |> List.last() |> to_string())

  defp rust_module_path?(_parts), do: false

  defp rust_module_name?(<<first, _rest::binary>>) when first in ?a..?z, do: true
  defp rust_module_name?(<<"_", _rest::binary>>), do: true
  defp rust_module_name?(_name), do: false

  # Iterating a borrowed collection with `into_iter` is `iter`.
  defp borrowed_iteration(:into_iter, [], nil), do: :into_iter

  defp borrowed_iteration(:into_iter, [], %Type{} = receiver_type) do
    if slice_type?(receiver_type) or receiver_type.kind in [:ref, :mut_ref],
      do: if(receiver_type.kind == :mut_ref, do: :iter_mut, else: :iter),
      else: :into_iter
  end

  defp borrowed_iteration(function, _args, _receiver_type), do: function

  # The variant a tagged tuple or atom names, with its payloads and their declared types.
  defp rust_enum_variant(pattern, %Type{meta: %{variants: variants}}) do
    {tag, payloads} =
      case pattern do
        tag when is_atom(tag) -> {tag, []}
        {:{}, _, [tag | payloads]} -> {tag, payloads}
        {tag, payload} -> {tag, [payload]}
        _other -> {nil, []}
      end

    case is_atom(tag) && List.keyfind(variants, tag, 0) do
      {^tag, types} -> {tag, payloads, types}
      _missing -> nil
    end
  end

  defp callable_target_from_type(%Type{} = type), do: Type.callable_target(type)
  defp callable_target_from_type(_type), do: nil

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
    do: %AST.Cast{expr: receiver, type: RustQ.Spec.type(type).ast}

  defp lower_pipe_call(
         receiver,
         {{:., _, [{:__aliases__, _, [:Kernel]}, operator]}, _, [right]},
         %Context{} = context
       )
       when operator in [:+, :-, :*, :/] do
    %AST.BinaryOp{left: receiver, op: operator_op(operator), right: lower_expr(right, context)}
  end

  defp lower_pipe_call(receiver, {name, _, args}, %Context{} = context)
       when is_atom(name) and is_list(args) do
    %AST.MethodCall{
      receiver: receiver,
      method: name,
      args: Enum.map(args, &lower_expr(&1, context))
    }
  end

  defp lower_pipe_call(_receiver, other, %Context{}) do
    Diagnostic.lower(
      :unsupported_pipeline_step,
      other,
      "unsupported defrust pipeline step",
      suggestion: "Pipe into a method call, cast/1, or add an explicit lowering clause."
    )
  end

  defp lower_binary_op(left, op, right, %Context{} = context) do
    %AST.BinaryOp{
      left: lower_binary_operand(left, context),
      op: op,
      right: lower_binary_operand(right, context)
    }
  end

  defp stdlib_context(%Context{} = context, expected \\ nil) do
    %StdlibContext{
      lower: &lower_expr(&1, context),
      lower_expected: &lower_expr(&1, &2, context),
      lower_binary_operand: &lower_binary_operand(&1, context),
      lower_closure: &lower_closure_args(&1, &2, context),
      lower_typed_closure: &lower_closure_args(&1, &2, context, &3),
      lower_closure_body: &lower_closure_body(&1, &2, context),
      lower_capture: &lower_function_capture(&1, context),
      closure_arg: &closure_arg!/1,
      type_of: &Typing.synth(&1, typing_env(context)),
      expected: expected
    }
  end

  defp lower_binary_operand(expression, %Context{} = context) do
    if fallible_expression?(expression, context) and propagation_allowed?(context.return_type) do
      %AST.Try{expr: lower_expr(expression, context)}
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
        context_with_match_pattern(pattern, type, acc)
      end)

    %AST.Closure{
      args: Enum.map(args, &closure_arg!/1),
      body: lower_closure_body(body, closure_return_type(expected_type), context)
    }
  end

  defp closure_context(args, context) do
    names = Enum.flat_map(args, &binding_pattern_names/1)

    %{
      context
      | vars: Map.drop(context.vars, names),
        lexical_vars: Map.drop(context.lexical_vars, names)
    }
  end

  defp lower_closure_args(args, body, %Context{} = context, expected_return_type \\ nil)
       when is_list(args) do
    {args, typed} = Enum.map_reduce(args, [], &untyped_closure_arg/2)

    captured =
      context.vars
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(context.captured)
      |> MapSet.difference(MapSet.new(Enum.flat_map(args, &binding_pattern_names/1)))

    context =
      Enum.reduce(typed, closure_context(args, context), fn {arg, type}, context ->
        context_with_match_pattern(arg, type, context)
      end)

    context = %{context | captured: captured}

    context = %{
      context
      | return_type: expected_return_type,
        scope_return_type: expected_return_type,
        position: :expr
    }

    %AST.Closure{
      args: Enum.map(args, &closure_arg!/1),
      body: lower_closure_body(body, expected_return_type, context)
    }
  end

  # A closure argument may carry the type of the items it is given, as an element of the list
  # an `Enum` function or comprehension iterates.
  defp untyped_closure_arg({:__rustq_typed_arg__, _, [arg, %Type{} = type]}, typed),
    do: {arg, [{arg, type} | typed]}

  defp untyped_closure_arg(arg, typed), do: {arg, typed}

  defp lower_closure_body(
         {:__block__, _, [_first, _second | _rest] = expressions},
         expected_return_type,
         %Context{} = context
       ) do
    body =
      case expected_return_type do
        %Type{} = type -> lower_expected_block(expressions, context, type)
        _none -> lower_value_block(expressions, context)
      end

    %AST.BlockExpr{body: body}
  end

  defp lower_closure_body(body, expected_return_type, %Context{} = context),
    do: lower_expr(closure_body_expr(body), expected_return_type, context)

  defp lower_value_block(expressions, %Context{} = context) do
    context = context_with_downstream_let_types(expressions, context)
    {statements, final} = split_final(expressions)

    Enum.map(statements, &lower_statement(&1, %{context | position: :statement})) ++
      [%AST.Return{expr: lower_expr(final, %{context | position: :return})}]
  end

  defp map_type?(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: map_type?(Type.ref_inner(type))

  defp map_type?(%Type{rust: rust}) when is_binary(rust),
    do: String.starts_with?(rust, ["HashMap<", "BTreeMap<"])

  defp map_type?(_type), do: false

  defp lower_function_capture({name, _, capture_context}, %Context{})
       when is_atom(name) and is_atom(capture_context),
       do: %AST.Path{parts: [name]}

  defp lower_function_capture(
         {{:., _, [{:__aliases__, _, [:Super]}, name]}, _, []},
         %Context{}
       ),
       do: %AST.Path{parts: [:super, name]}

  defp lower_function_capture(
         {{:., _, [{:__aliases__, _, parts}, name]}, _, []},
         %Context{} = context
       ),
       do: %AST.Path{parts: mapped_alias_parts(parts, context.rust_modules) ++ [name]}

  defp lower_function_capture(other, %Context{}) do
    Diagnostic.lower(
      :unsupported_function_capture,
      other,
      "unsupported function capture in defrust",
      suggestion: "Capture a named local or remote function with arity one."
    )
  end

  defp closure_arg!({name, _, context}) when is_atom(name) and is_atom(context), do: name

  defp closure_arg!(other), do: lower_binding_pattern(other)

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
    path = %AST.Path{parts: [part]}

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
        super_alias_ast?(receiver) -> [:super, macro_call_part(function)]
        alias_ast?(receiver) -> alias_parts(receiver, rust_modules) ++ [macro_call_part(function)]
        true -> nil
      end

    if path_parts do
      %AST.MacroCall{
        path: %AST.Path{parts: path_parts},
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

  defp lower_semantic_pat({:ident, _, [name]}, %Context{}),
    do: %AST.PatVar{name: semantic_atom!(name)}

  defp lower_semantic_pat({:mut_ident, _, [name]}, %Context{}),
    do: %AST.PatVar{name: semantic_atom!(name), mutable: true}

  defp lower_semantic_pat({:path, _, [path]}, %Context{} = context),
    do: %AST.PatPath{path: lower_expr_path(path, context)}

  defp lower_semantic_pat({:some, _, [pattern]}, %Context{} = context),
    do: %AST.PatSome{pattern: lower_semantic_pat(pattern, context)}

  defp lower_semantic_pat({:ok, pattern}, %Context{} = context),
    do: %AST.PatOk{pattern: lower_semantic_pat(pattern, context)}

  defp lower_semantic_pat({:error, pattern}, %Context{} = context),
    do: %AST.PatErr{pattern: lower_semantic_pat(pattern, context)}

  defp lower_semantic_pat({:{}, _, [:ok, pattern]}, %Context{} = context),
    do: %AST.PatOk{pattern: lower_semantic_pat(pattern, context)}

  defp lower_semantic_pat({:{}, _, [:error, pattern]}, %Context{} = context),
    do: %AST.PatErr{pattern: lower_semantic_pat(pattern, context)}

  defp lower_semantic_pat({:tuple, _, [patterns]}, %Context{} = context),
    do: %AST.PatTuple{patterns: Enum.map(patterns, &lower_semantic_pat(&1, context))}

  defp lower_semantic_pat({:path_tuple, _, [path, patterns]}, %Context{} = context),
    do: %AST.PatPathTuple{
      path: lower_expr_path(path, context),
      patterns: Enum.map(patterns, &lower_semantic_pat(&1, context))
    }

  defp lower_semantic_pat({:struct, _, [path, fields]}, %Context{} = context),
    do: %AST.PatStruct{
      path: lower_expr_path(path, context),
      fields: lower_semantic_pat_fields(fields, context)
    }

  defp lower_semantic_pat(nil, %Context{}), do: %AST.PatNone{}
  defp lower_semantic_pat(:_, %Context{}), do: %AST.PatWildcard{}
  defp lower_semantic_pat({:_, _, _}, %Context{}), do: %AST.PatWildcard{}

  defp lower_semantic_pat(other, %Context{} = context),
    do: lower_match_pattern(other, nil, context)

  defp lower_semantic_pat_fields(fields, %Context{} = context) when is_list(fields) do
    Enum.map(fields, fn {name, pattern} -> {name, lower_semantic_pat(pattern, context)} end)
  end

  defp lower_semantic_arm_body(body, %Context{} = context),
    do: lower_clause_body(body, %{context | position: :return})

  defp lower_expr_path(%AST.Path{} = path, %Context{}), do: path

  defp lower_expr_path(expression, %Context{} = context) do
    case lower_expr(expression, context) do
      %AST.Path{} = path ->
        path

      other ->
        Diagnostic.lower(
          :expected_rust_path,
          expression,
          "expected Rust path, got: #{inspect(other)}"
        )
    end
  end

  defp semantic_atom!(atom) when is_atom(atom), do: atom
  defp semantic_atom!({name, _, context}) when is_atom(name) and is_atom(context), do: name

  defp semantic_atom!(other) do
    Diagnostic.lower(:expected_atom_identifier, other, "expected atom identifier")
  end

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
    %AST.PathCall{
      path: %AST.Path{parts: [:super, "parse_syn::<#{type}>"]},
      args: [quote_tokens(tokens)]
    }
  end

  defp quote_tokens(tokens) when is_binary(tokens),
    do: %AST.TokenMacro{path: %AST.Path{parts: [:quote]}, tokens: tokens}

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
      Enum.find_value(alias_prefixes(parts), fn {prefix, suffix} ->
        case Map.fetch(context.rust_modules, prefix) do
          {:ok, mapped} -> mapped ++ suffix
          :error -> nil
        end
      end)

    if explicit do
      %AST.Path{parts: explicit}
    else
      type_ast = {{:., meta, [alias_ast, :t]}, meta, []}
      %AST.TypePath{parts: resolved} = RustQ.Spec.type(type_ast, context.type_aliases).ast
      %AST.Path{parts: resolved}
    end
  end

  defp lower_struct_literal_path(path, %Context{} = context), do: lower_expr(path, context)

  defp enum_variant_path(path, variant), do: enum_variant_path(path, variant, %Context{})

  defp enum_variant_path(path, variant, %Context{} = context) do
    %AST.Path{parts: parts} = lower_expr(path, context)
    %AST.Path{parts: parts ++ [rust_variant(semantic_atom!(variant))]}
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
      do: %AST.MethodCall{receiver: lowered, method: :clone, args: []},
      else: lowered
  end

  defp clone_captured(lowered, _base, _context), do: lowered

  # `%{value | field: new}` copies the struct with the listed fields replaced.
  defp lower_struct_update(base, fields, %Context{} = context) do
    case infer_expr_type(base, context.vars) || Typing.synth(base, typing_env(context)) do
      %Type{kind: :struct, ast: %AST.TypePath{parts: parts}} = type ->
        %AST.StructLiteral{
          path: %AST.Path{parts: parts},
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

  defp lower_token_macro_path(atom) when is_atom(atom), do: %AST.Path{parts: [atom]}
  defp lower_token_macro_path({:__aliases__, _, parts}), do: %AST.Path{parts: parts}

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

  defp infer_expr_type({name, _, context}, vars) when is_atom(name) and is_atom(context),
    do: Map.get(vars, name)

  defp infer_expr_type(_expression, _vars), do: nil

  defp context_with_downstream_let_types(expressions, %Context{} = context) do
    inferred =
      Typing.infer_downstream_let_types(
        expressions,
        typing_env(context),
        Map.put(inference_callbacks(context), :block_return_type, context.return_type)
      )

    %{context | vars: Map.merge(context.vars, inferred), lexical_vars: context.vars}
  end

  defp context_with_lexical_pattern_vars(pattern, %Context{} = context) do
    vars =
      pattern
      |> binding_pattern_names()
      |> Enum.reduce(context.vars, fn name, vars ->
        case Map.fetch(context.lexical_vars, name) do
          {:ok, type} -> Map.put(vars, name, type)
          :error -> vars
        end
      end)

    %{context | vars: vars}
  end

  defp binding_pattern_names({name, _meta, ast_context})
       when is_atom(name) and is_atom(ast_context) and name != :_,
       do: [name]

  defp binding_pattern_names(pattern) do
    case Pattern.tuple_elements(pattern) do
      elements when is_list(elements) -> Enum.flat_map(elements, &binding_pattern_names/1)
      _not_tuple -> []
    end
  end

  defp inference_callbacks(%Context{} = context) do
    callables = context.callables

    %{
      return_type: &callable_return_type(&1, callables: callables, vars: context.vars),
      local_argument_types: fn name, arity ->
        callable_argument_types(callables, nil, name, arity)
      end,
      path_argument_types: fn parts, function, arity ->
        path = alias_parts({:__aliases__, [], parts}, context.rust_modules) ++ [function]
        path_callable_argument_types(path, function, arity, callables, context.rust_modules)
      end,
      method_argument_types: fn target, function, arity ->
        callable_argument_types(callables, target, function, arity)
      end,
      target_type: &callable_target_from_type/1,
      method_receiver_type: &method_receiver_type(&1, &2, callables),
      struct_type: &declared_struct_type(&1, context)
    }
  end

  defp method_receiver_type(function, arity, %BindingIndex{} = callables) do
    case BindingIndex.method_targets(callables, function, arity) do
      [target] -> type_for_callable_target(target)
      _ambiguous_or_missing -> nil
    end
  end

  defp type_for_callable_target(target) when is_binary(target) do
    ast =
      case callable_target_parts(target) do
        [_ | _] = parts -> %AST.TypePath{parts: parts}
        nil -> %AST.TypeRaw{source: target}
      end

    %Type{kind: :type, rust: target, ast: ast}
  end

  defp callable_target_parts(target) do
    parts = String.split(target, "::")

    if Enum.all?(parts, &simple_rust_identifier?/1) do
      Enum.map(parts, &Identifier.atom!/1)
    end
  end

  defp simple_rust_identifier?(<<first, rest::binary>>) when first in ?A..?Z or first in ?a..?z,
    do: simple_rust_identifier_tail?(rest)

  defp simple_rust_identifier?(<<"_", rest::binary>>), do: simple_rust_identifier_tail?(rest)
  defp simple_rust_identifier?(""), do: false

  defp simple_rust_identifier_tail?(<<>>), do: true

  defp simple_rust_identifier_tail?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9,
       do: simple_rust_identifier_tail?(rest)

  defp simple_rust_identifier_tail?(<<"_", rest::binary>>), do: simple_rust_identifier_tail?(rest)
  defp simple_rust_identifier_tail?(_invalid), do: false

  defp infer_mutability(body) do
    mutable_vars = body |> collect_mutable_let_refs() |> MapSet.new()

    Walk.postwalk(body, fn
      %AST.Let{pattern: %AST.PatVar{name: name}, expr: %AST.Ref{}} = let ->
        %{let | mutable: rebound_or_borrowed?(body, name)}

      %AST.Let{pattern: %AST.PatVar{name: name}} = let ->
        %{let | mutable: MapSet.member?(mutable_vars, name)}

      %AST.Let{pattern: %AST.PatTuple{} = pattern} = let ->
        %{let | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

      %AST.Closure{args: args, body: closure_body} = closure ->
        %{closure | args: mutable_closure_args(args, closure_body)}

      other ->
        other
    end)
  end

  # A closure argument its body changes, such as a fold accumulator, is bound `mut`.
  defp mutable_closure_args(args, body) do
    mutated = body |> collect_mutable_let_refs() |> MapSet.new()

    Enum.map(args, fn
      name when is_atom(name) ->
        if MapSet.member?(mutated, name), do: %AST.PatVar{name: name, mutable: true}, else: name

      pattern ->
        pattern
    end)
  end

  # The variable a statement-level method chain starts from, when its first method changes
  # its receiver, as in `map.entry(key).or_default().push(value)`.
  defp mutated_chain_root(%AST.MethodCall{receiver: %AST.Var{name: name}, method: method}),
    do: if(mutating_method?(method), do: name)

  defp mutated_chain_root(%AST.MethodCall{receiver: receiver}), do: mutated_chain_root(receiver)
  defp mutated_chain_root(_expression), do: nil

  @doc "Whether a method changes its receiver, as std collections' `&mut self` methods do."
  @spec mutating_method?(atom()) :: boolean()
  def mutating_method?(method),
    do: method in @mutating_methods or String.ends_with?(Atom.to_string(method), "_mut")

  defp rebound_or_borrowed?(body, name) do
    Walk.reduce(body, false, fn
      %AST.Assign{target: %AST.Var{name: ^name}}, _ -> true
      %AST.Ref{mutable: true, expr: %AST.Var{name: ^name}}, _ -> true
      _, found -> found
    end)
  end

  defp collect_pattern_mutations(term, context) do
    Walk.reduce(term, collect_mut_refs(term), fn
      %AST.ExprStmt{
        expr: %AST.MethodCall{receiver: %AST.Var{name: name}, method: method, args: args}
      },
      acc ->
        if mutable_method?(context, name, method, length(args)), do: [name | acc], else: acc

      _, acc ->
        acc
    end)
  end

  defp mutable_method?(context, name, method, arity) do
    targets =
      case Map.get(context.vars, name) do
        %Type{} = type ->
          case type |> StandardPointer.receiver() |> Type.callable_target() do
            nil -> []
            target -> [target]
          end

        nil ->
          []
      end

    targets != [] and
      Enum.all?(targets, fn target ->
        match?(
          %{args: [%{type: %Type{kind: :mut_ref}} | _]},
          BindingIndex.get(context.callables, target, method, arity)
        )
      end)
  end

  defp collect_mut_refs(term) do
    Walk.reduce(term, [], fn
      %AST.Ref{mutable: true, expr: %AST.Var{name: name}}, acc -> [name | acc]
      _other, acc -> acc
    end)
  end

  defp collect_mutable_let_refs(term) do
    Walk.reduce(term, [], fn
      %AST.ExprStmt{expr: %AST.MethodCall{receiver: %AST.Var{name: name}}}, acc ->
        [name | acc]

      %AST.ExprStmt{expr: %AST.MethodCall{} = call}, acc ->
        case mutated_chain_root(call) do
          nil -> acc
          name -> [name | acc]
        end

      %AST.Assign{target: %AST.Var{name: name}}, acc ->
        [name | acc]

      %AST.AssignOp{target: %AST.Var{name: name}}, acc ->
        [name | acc]

      %AST.Assign{target: %AST.Index{receiver: %AST.Var{name: name}}}, acc ->
        [name | acc]

      %AST.AssignOp{target: %AST.Index{receiver: %AST.Var{name: name}}}, acc ->
        [name | acc]

      %AST.Assign{target: %AST.Field{receiver: %AST.Var{name: name}}}, acc ->
        [name | acc]

      %AST.AssignOp{target: %AST.Field{receiver: %AST.Var{name: name}}}, acc ->
        [name | acc]

      %AST.Ref{mutable: true, expr: %AST.Var{name: name}}, acc ->
        [name | acc]

      # A changing method used as a value, as in `if seen.insert(key)`.
      %AST.MethodCall{} = call, acc ->
        case mutated_chain_root(call) do
          nil -> acc
          name -> [name | acc]
        end

      _other, acc ->
        acc
    end)
  end

  defp typing_env(%Context{} = context) do
    Typing.env(
      type_aliases: context.type_aliases,
      vars: context.vars,
      callables: context.callables,
      rust_modules: context.rust_modules
    )
  end

  defp alias_ast?({:__aliases__, _, _parts}), do: true
  defp alias_ast?(_other), do: false

  defp alias_path_ast?({:__aliases__, _, _parts}), do: true

  defp alias_path_ast?({{:., _, [receiver, _field]}, meta, []}),
    do: Keyword.get(meta, :no_parens, false) and alias_path_ast?(receiver)

  defp alias_path_ast?(_other), do: false

  defp super_alias_ast?({:__aliases__, _, [:Super]}), do: true
  defp super_alias_ast?(_other), do: false

  defp rust_constructor_alias?({:__aliases__, _, [module]}) when module in [:Stmt], do: true
  defp rust_constructor_alias?(_other), do: false

  defp rust_variant(name), do: Identifier.atom!(Macro.camelize(Atom.to_string(name)))

  defp alias_parts({:__aliases__, _, parts}, rust_modules),
    do: mapped_alias_parts(parts, rust_modules)

  defp alias_path_parts(ast, rust_modules),
    do: ast |> raw_alias_path_parts() |> mapped_alias_parts(rust_modules)

  defp raw_alias_path_parts(ast), do: raw_alias_path_parts(ast, [])

  defp raw_alias_path_parts({:__aliases__, _, parts}, acc) do
    parts
    |> Enum.reverse()
    |> Enum.reduce(acc, &[&1 | &2])
  end

  defp raw_alias_path_parts({{:., _, [receiver, field]}, meta, []} = ast, acc) do
    if Keyword.get(meta, :no_parens, false) do
      raw_alias_path_parts(receiver, [field | acc])
    else
      Diagnostic.lower(:unsupported_alias_path, ast, "unsupported alias path")
    end
  end

  defp mapped_alias_parts(parts, rust_modules) do
    parts
    |> alias_prefixes()
    |> Enum.find_value(fn {prefix, suffix} ->
      mapped = Map.get(rust_modules, prefix)
      if mapped, do: mapped ++ suffix
    end) || automatic_rust_alias_parts(parts)
  end

  defp alias_prefixes(parts) do
    parts
    |> length()
    |> Range.new(1, -1)
    |> Enum.map(fn count -> Enum.split(parts, count) end)
  end

  defp automatic_rust_alias_parts(parts) do
    if rust_module_alias?(parts) do
      Enum.map(parts, &rust_module_part/1)
    else
      parts
    end
  end

  defp rust_module_alias?(parts) do
    parts
    |> List.last()
    |> Atom.to_string()
    |> String.ends_with?("s")
  end

  defp rust_module_part(part),
    do: Identifier.atom!(Macro.underscore(Atom.to_string(part)))

  defp callable_return_type_from_index(
         {name, _meta, args},
         %BindingIndex{} = callables,
         _rust_modules,
         _vars
       )
       when is_atom(name) and is_list(args) do
    BindingIndex.return_type(callables, nil, name, length(args))
  end

  defp callable_return_type_from_index(
         {{:., _, [{:__aliases__, _, parts}, function]}, _meta, args},
         %BindingIndex{} = callables,
         rust_modules,
         _vars
       )
       when is_atom(function) and is_list(args) do
    arity = length(args)

    callable_return_type_for_path(parts, function, arity, callables, rust_modules)
  end

  defp callable_return_type_from_index(
         {{:., _, [receiver, function]}, _meta, args},
         %BindingIndex{} = callables,
         _rust_modules,
         vars
       )
       when is_atom(function) and is_list(args) do
    target =
      receiver
      |> infer_expr_type(vars)
      |> callable_target_from_type()

    BindingIndex.return_type(callables, target, function, length(args))
  end

  defp callable_return_type_from_index(_call_ast, %BindingIndex{}, _rust_modules, _vars), do: nil

  defp callable_return_type_for_path(
         parts,
         function,
         arity,
         callables,
         rust_modules
       ) do
    parent_module_callable_return_type(parts, function, arity, callables) ||
      parts
      |> callable_target_candidates(rust_modules)
      |> Enum.find_value(&BindingIndex.return_type(callables, &1, function, arity)) ||
      path_module_fallback_return_type(parts, function, arity, callables)
  end

  defp exact_callable_target_candidates(parts, rust_modules) do
    mapped = mapped_alias_parts(parts, rust_modules)

    [
      Enum.map_join(mapped, "::", &to_string/1),
      mapped |> List.last() |> to_string(),
      Enum.map_join(parts, "::", &to_string/1),
      parts |> List.last() |> to_string()
    ]
    |> Enum.uniq()
  end

  defp callable_target_candidates(parts, rust_modules) do
    mapped = mapped_alias_parts(parts, rust_modules)
    mapped_last = List.last(mapped)
    parts_last = List.last(parts)

    [
      Enum.map_join(mapped, "::", &to_string/1),
      to_string(mapped_last),
      singular_candidate(mapped_last),
      singular_module_candidate(mapped_last),
      Enum.map_join(parts, "::", &to_string/1),
      to_string(parts_last),
      singular_candidate(parts_last),
      singular_module_candidate(parts_last)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp singular_candidate(part) when is_atom(part),
    do: part |> to_string() |> singular_candidate()

  defp singular_candidate(part) when is_binary(part) do
    if String.ends_with?(part, "s") and String.length(part) > 1 do
      String.trim_trailing(part, "s")
    end
  end

  defp singular_candidate(_part), do: nil

  defp singular_module_candidate(part) do
    case singular_candidate(part) do
      nil -> nil
      singular -> Macro.camelize(singular)
    end
  end

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
