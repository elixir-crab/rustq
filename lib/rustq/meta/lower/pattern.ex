defmodule RustQ.Meta.Lower.Pattern do
  @moduledoc """
  Elixir patterns as Rust patterns: in `case` clauses, `with` clauses, bindings, closure
  arguments, and comprehension generators.

  Tuples, lists, structs, `{:some, value}`, `{:ok, value}`, `{:error, reason}`, atoms, and enum
  variants lower to the Rust patterns matching the same values, by the type matched. Matching
  binds the pattern's variables with the types it reveals, which the clause body lowers with.
  """

  alias RustQ.Binding.Index, as: BindingIndex
  alias RustQ.Diagnostic
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Lower.Env, as: Context
  alias RustQ.Meta.Lower.Paths
  alias RustQ.Meta.Pattern, as: ElixirPattern
  alias RustQ.Meta.StandardPointer
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.Walk

  @doc "Whether `case` clauses match `{:ok, _}`/`{:error, _}` or `{:some, _}`/`nil`."
  def wrapper_case_patterns?(%Type{kind: kind}, clauses) when kind in [:result, :nif_result] do
    Enum.any?(clauses, fn {:->, _, [[pattern], _body]} ->
      pattern |> split_guarded_pattern() |> elem(0) |> result_pattern?()
    end)
  end

  def wrapper_case_patterns?(%Type{kind: :option}, clauses) do
    Enum.any?(clauses, fn {:->, _, [[pattern], _body]} ->
      pattern |> split_guarded_pattern() |> elem(0) |> option_pattern?()
    end)
  end

  def wrapper_case_patterns?(%Type{}, _clauses), do: false

  @doc "The Rust pattern a `with` clause pattern is."
  # A `with` pattern matches what its expression gives; a bare variable binds all of it.
  def lower_with_pattern({name, _, ast_context} = pattern, _type, %Context{} = context)
      when is_atom(name) and is_atom(ast_context),
      do: lower_match_pattern(pattern, nil, context)

  def lower_with_pattern(pattern, type, %Context{} = context),
    do: lower_match_pattern(pattern, type, context)

  @doc "A pattern with its comprehension filters as its guard."
  def guarded_pattern(pattern, []), do: pattern

  def guarded_pattern(pattern, filters) do
    guard =
      Enum.reduce(filters, fn filter, guard -> quote(do: unquote(guard) and unquote(filter)) end)

    quote(do: unquote(pattern) when unquote(guard))
  end

  @doc "Whether `pattern` only binds, so it cannot fail to match."
  def binding_pattern?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true

  def binding_pattern?(pattern) do
    case ElixirPattern.tuple_elements(pattern) do
      elements when is_list(elements) -> Enum.all?(elements, &binding_pattern?/1)
      _not_tuple -> false
    end
  end

  @doc "The variables a pattern binds, as one variable or a tuple of them."
  # The variables a pattern binds, as one variable or a tuple of them.
  def pattern_binder(pattern) do
    case ElixirPattern.variables(pattern) do
      [] -> quote(do: {})
      [variable] -> variable
      variables -> {:{}, [], variables}
    end
  end

  @doc "The type a `case` scrutinee has, as its clauses' patterns reveal it."
  def infer_case_type_from_patterns(clauses) do
    if Enum.any?(clauses, fn {:->, _, [[pattern], _body]} -> option_pattern?(pattern) end) do
      %Type{kind: :option}
    end
  end

  defp option_pattern?(nil), do: true

  defp option_pattern?(:none), do: true

  defp option_pattern?({:some, _pattern}), do: true

  defp option_pattern?({:{}, _, [:some, _pattern]}), do: true

  defp option_pattern?(_pattern), do: false

  @doc "Whether `pattern` matches a list."
  def list_pattern?([]), do: true

  def list_pattern?([_head | _tail]), do: true

  def list_pattern?(_pattern), do: false

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

  @doc "The Rust pattern a binding pattern is."
  def lower_binding_pattern({name, _, context}) when is_atom(name) and is_atom(context),
    do: %AST.PatVar{name: name}

  def lower_binding_pattern({:{}, _, values}),
    do: %AST.PatTuple{patterns: Enum.map(values, &lower_binding_pattern/1)}

  def lower_binding_pattern({left, right}),
    do: %AST.PatTuple{patterns: Enum.map([left, right], &lower_binding_pattern/1)}

  def lower_binding_pattern(other) do
    Diagnostic.lower(
      :unsupported_binding_pattern,
      other,
      "unsupported defrust binding pattern",
      suggestion: "Use a variable or tuple pattern."
    )
  end

  @doc "A clause head split into its pattern and guard."
  def split_guarded_pattern({:when, _, [pattern, guard]}), do: {pattern, guard}

  def split_guarded_pattern(pattern), do: {pattern, nil}

  @doc "`context` with the variables `pattern` binds, typed by the value of `type` it matches."
  def context_with_match_pattern(pattern, %Type{kind: :option} = type, %Context{} = context) do
    context_with_inner_pattern(pattern, Type.inner(type), [:some], context)
  end

  def context_with_match_pattern(pattern, %Type{kind: kind} = type, %Context{} = context)
      when kind in [:result, :nif_result] do
    context_with_inner_pattern(pattern, Type.inner(type), [:ok], context)
  end

  def context_with_match_pattern([], %Type{kind: :vec} = type, %Context{} = context),
    do: context_with_list_pattern([], type, context)

  def context_with_match_pattern(pattern, %Type{} = type, %Context{} = context)
      when is_list(pattern) and type.kind == :slice,
      do: context_with_list_pattern(pattern, type, context)

  def context_with_match_pattern(
        [_head | _tail] = pattern,
        %Type{kind: :vec} = type,
        %Context{} = context
      ),
      do: context_with_list_pattern(pattern, type, context)

  def context_with_match_pattern(
        {:%{}, _, fields},
        %Type{kind: :struct} = type,
        %Context{} = context
      )
      when is_list(fields),
      do: context_with_struct_pattern(fields, type, context)

  def context_with_match_pattern(
        {:%, _, [_module, {:%{}, _, fields}]},
        %Type{kind: :struct} = type,
        %Context{} = context
      )
      when is_list(fields),
      do: context_with_struct_pattern(fields, type, context)

  def context_with_match_pattern(
        {name, _meta, ast_context},
        %Type{} = type,
        %Context{} = context
      )
      when is_atom(name) and is_atom(ast_context) do
    %{context | vars: Map.put(context.vars, name, type)}
  end

  def context_with_match_pattern(pattern, %Type{kind: :rust_enum} = type, %Context{} = context),
    do: context_with_variant_pattern(pattern, type, & &1, context)

  def context_with_match_pattern(
        pattern,
        %Type{kind: kind, meta: %{inner: %Type{kind: :rust_enum} = inner}},
        %Context{} = context
      )
      when kind in [:ref, :mut_ref],
      do: context_with_variant_pattern(pattern, inner, &Type.ref/1, context)

  def context_with_match_pattern(pattern, %Type{kind: :tuple, meta: %{elements: types}}, context) do
    case ElixirPattern.tuple_elements(pattern) do
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

  # A pattern on a reference to an option binds a reference to what it holds, as Rust's
  # default binding mode does.
  def context_with_match_pattern(
        pattern,
        %Type{kind: :ref, meta: %{inner: %Type{kind: :option} = option}},
        %Context{} = context
      ),
      do: context_with_match_pattern(pattern, Type.option(Type.ref(Type.inner(option))), context)

  # A tuple pattern on a reference to a tuple binds references to its elements, as Rust's
  # default binding mode does.
  def context_with_match_pattern(pattern, %Type{kind: :ref} = type, %Context{} = context)
      when is_tuple(pattern) and (tuple_size(pattern) == 2 or elem(pattern, 0) == :{}) do
    case Type.ref_inner(type) do
      %Type{kind: :tuple, meta: %{elements: types}} = tuple ->
        refs = Enum.map(types, &Type.ref/1)

        context_with_match_pattern(
          pattern,
          %{tuple | meta: %{tuple.meta | elements: refs}},
          context
        )

      _other ->
        context_with_match_pattern(pattern, nil, context)
    end
  end

  # A pattern of unknown type still shadows the names it binds; they lose their old types.
  def context_with_match_pattern(pattern, _type, %Context{} = context) do
    names = pattern |> ElixirPattern.variables() |> Enum.map(&elem(&1, 0))
    %{context | vars: Map.drop(context.vars, names)}
  end

  defp context_with_variant_pattern(pattern, type, payload_type, %Context{} = context) do
    case Lower.rust_enum_variant(pattern, type) do
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
    # A list is matched as a slice, so its items bind by reference.
    item = if inner && type.kind in [:slice, :vec], do: Type.ref(inner), else: inner

    context =
      Enum.reduce(elements, context, fn element, acc ->
        context_with_match_pattern(element, item, acc)
      end)

    if rest,
      do: context_with_match_pattern(rest, Type.slice_ref(inner), context),
      else: context
  end

  @doc "`context` with the variables a generator pattern binds, typed by the items it matches."
  def context_with_for_pattern(pattern, expression, %Context{} = context) do
    expression
    |> Lower.infer_expr_type(context.vars)
    |> Kernel.||(Typing.synth(expression, Lower.typing_env(context)))
    |> for_item_type()
    |> case do
      %Type{} = item_type -> context_with_match_pattern(pattern, item_type, context)
      nil -> context
    end
  end

  # A loop over a slice, or over a list behind a reference, reads each item by reference.
  defp for_item_type(%Type{kind: kind} = type) when kind in [:ref, :mut_ref] do
    case type |> Type.ref_inner() |> for_item_type() do
      %Type{kind: kind} = item when kind not in [:ref, :mut_ref] -> Type.ref(item)
      item -> item
    end
  end

  defp for_item_type(%Type{kind: :slice} = type) do
    case Type.slice_inner(type) do
      %Type{} = item -> Type.ref(item)
      nil -> nil
    end
  end

  defp for_item_type(%Type{} = type), do: Type.vec_inner(type)
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

  @doc "The Rust pattern a `case` pattern is, matching a value of `type`."
  # Patterns name constants and enum variants through the module's Rust module aliases.
  def lower_match_pattern(pattern, case_type, %Context{} = context),
    do: pattern |> resolve_pattern_paths(context) |> lower_match_pattern(case_type)

  defp resolve_pattern_paths(pattern, %Context{} = context) do
    Macro.prewalk(pattern, fn
      {:enum_variant, meta, [{:__aliases__, _, parts} | rest]} ->
        {:enum_variant, meta, [rust_path_marker(parts, context) | rest]}

      {:__aliases__, _, parts} = alias ->
        if Paths.constant_alias?(parts), do: rust_path_marker(parts, context), else: alias

      other ->
        other
    end)
  end

  defp rust_path_marker(parts, %Context{} = context),
    do: {:__rustq_path__, [], Paths.mapped_alias_parts(parts, context.rust_modules)}

  def lower_match_pattern({:__rustq_path__, _, parts}, _case_type),
    do: %AST.PatPath{path: A.path(parts)}

  def lower_match_pattern(:ok, %Type{kind: kind}) when kind in [:result, :nif_result],
    do: %AST.PatOk{pattern: %AST.PatTuple{patterns: []}}

  def lower_match_pattern(nil, %Type{kind: :option}), do: %AST.PatNone{}

  def lower_match_pattern(:none, %Type{kind: :option}), do: %AST.PatNone{}

  def lower_match_pattern(nil, _case_type), do: %AST.PatNone{}

  def lower_match_pattern(:none, _case_type), do: %AST.PatNone{}

  def lower_match_pattern({:_, _, _}, _case_type), do: %AST.PatWildcard{}

  def lower_match_pattern(value, _case_type)
      when is_binary(value) or is_integer(value) or is_boolean(value),
      do: %AST.PatLiteral{value: value}

  def lower_match_pattern([ok: pattern], _case_type),
    do: %AST.PatOk{pattern: lower_match_pattern(pattern, nil)}

  def lower_match_pattern([error: pattern], _case_type),
    do: %AST.PatErr{pattern: lower_match_pattern(pattern, nil)}

  def lower_match_pattern({:ok, pattern}, _case_type),
    do: %AST.PatOk{pattern: lower_match_pattern(pattern, nil)}

  def lower_match_pattern({:error, pattern}, _case_type),
    do: %AST.PatErr{pattern: lower_match_pattern(pattern, nil)}

  def lower_match_pattern({:some, pattern}, %Type{kind: :option} = type),
    do: %AST.PatSome{pattern: lower_tuple_element_pattern(pattern, Type.inner(type))}

  def lower_match_pattern({:some, pattern}, _case_type),
    do: %AST.PatSome{pattern: lower_match_pattern(pattern, nil)}

  def lower_match_pattern({:{}, _, [:some, pattern]}, %Type{kind: :option} = type),
    do: %AST.PatSome{pattern: lower_tuple_element_pattern(pattern, Type.inner(type))}

  def lower_match_pattern({:{}, _, [:some, pattern]}, _case_type),
    do: %AST.PatSome{pattern: lower_match_pattern(pattern, nil)}

  def lower_match_pattern({:enum_variant, _, [path, variant]}, _case_type) do
    %AST.PatPath{path: Lower.enum_variant_path(path, variant)}
  end

  def lower_match_pattern({:enum_variant, _, [path, variant | patterns]}, _case_type) do
    %AST.PatPathTuple{
      path: Lower.enum_variant_path(path, variant),
      patterns: Enum.map(patterns, &lower_match_pattern(&1, nil))
    }
  end

  def lower_match_pattern([], %Type{kind: :vec} = type), do: lower_list_pattern([], type)

  def lower_match_pattern(pattern, %Type{kind: :slice} = type) when is_list(pattern),
    do: lower_list_pattern(pattern, type)

  # A list pattern on a value of unknown type matches it as a slice; a keyword list does not.
  def lower_match_pattern([head | _tail] = pattern, nil)
      when not (is_tuple(head) and tuple_size(head) == 2 and is_atom(elem(head, 0))),
      do: lower_list_pattern(pattern, nil)

  def lower_match_pattern([_head | _tail] = pattern, %Type{kind: :vec} = type),
    do: lower_list_pattern(pattern, type)

  def lower_match_pattern(
        {:%{}, _, fields},
        %Type{kind: :struct, rust: rust_name, meta: %{fields: type_fields}}
      )
      when is_list(fields) do
    %AST.PatStruct{
      path: A.path([rust_name]),
      fields: lower_struct_pattern_fields(fields, type_fields)
    }
  end

  def lower_match_pattern(
        {:%, _, [_module, {:%{}, _, fields}]},
        %Type{kind: :struct, rust: rust_name, meta: %{fields: type_fields}}
      )
      when is_list(fields) do
    %AST.PatStruct{
      path: A.path([rust_name]),
      fields: lower_struct_pattern_fields(fields, type_fields)
    }
  end

  def lower_match_pattern({:%, _, [{:__aliases__, _, modules}, {:%{}, _, fields}]}, %Type{
        kind: :tuple_enum,
        rust: rust_name
      }) do
    module = List.last(modules)

    %AST.PatPathTuple{
      path: A.path([rust_name, module]),
      patterns: [
        %AST.PatStruct{
          path: A.path([module]),
          fields:
            Enum.map(fields, fn {name, pattern} -> {name, lower_match_pattern(pattern, nil)} end)
        }
      ]
    }
  end

  def lower_match_pattern({name, _, context}, %Type{kind: :option})
      when is_atom(name) and is_atom(context),
      do: %AST.PatSome{pattern: %AST.PatVar{name: name}}

  def lower_match_pattern({name, _, context}, _case_type)
      when is_atom(name) and is_atom(context),
      do: %AST.PatVar{name: name}

  # A borrowed enum matches its variants as they are, binding payloads by reference.
  def lower_match_pattern(
        pattern,
        %Type{kind: kind, meta: %{inner: %Type{kind: :rust_enum} = inner}}
      )
      when kind in [:ref, :mut_ref] and (is_atom(pattern) or is_tuple(pattern)),
      do: lower_match_pattern(pattern, inner)

  def lower_match_pattern(pattern, %Type{kind: :rust_enum, rust: rust_name} = type)
      when is_atom(pattern) or is_tuple(pattern) do
    case Lower.rust_enum_variant(pattern, type) do
      {variant, [], _types} ->
        %AST.PatPath{path: A.path([rust_name, Lower.rust_variant(variant)])}

      {variant, payloads, types} when length(payloads) == length(types) ->
        %AST.PatPathTuple{
          path: A.path([rust_name, Lower.rust_variant(variant)]),
          patterns: Enum.zip_with(payloads, types, &lower_tuple_element_pattern/2)
        }

      _other ->
        lower_match_pattern(pattern, nil)
    end
  end

  def lower_match_pattern(atom, %Type{kind: :enum, rust: rust_name}) when is_atom(atom),
    do: %AST.PatPath{path: A.path([rust_name, Lower.rust_variant(atom)])}

  def lower_match_pattern(atom, %Type{kind: :atom}) when is_atom(atom),
    do: %AST.PatAtomGuard{name: atom}

  def lower_match_pattern(atom, _case_type) when is_atom(atom), do: %AST.PatAtomGuard{name: atom}

  def lower_match_pattern({:{}, _, values}, case_type),
    do: lower_tuple_match_pattern(values, case_type)

  def lower_match_pattern({left, right}, case_type),
    do: lower_tuple_match_pattern([left, right], case_type)

  def lower_match_pattern(other, _case_type) do
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

  @doc "The Rust pattern a pattern over atoms and enum variants is."
  def lower_semantic_pat({:ident, _, [name]}, %Context{}),
    do: %AST.PatVar{name: semantic_atom!(name)}

  def lower_semantic_pat({:mut_ident, _, [name]}, %Context{}),
    do: %AST.PatVar{name: semantic_atom!(name), mutable: true}

  def lower_semantic_pat({:path, _, [path]}, %Context{} = context),
    do: %AST.PatPath{path: lower_expr_path(path, context)}

  def lower_semantic_pat({:some, _, [pattern]}, %Context{} = context),
    do: %AST.PatSome{pattern: lower_semantic_pat(pattern, context)}

  def lower_semantic_pat({:ok, pattern}, %Context{} = context),
    do: %AST.PatOk{pattern: lower_semantic_pat(pattern, context)}

  def lower_semantic_pat({:error, pattern}, %Context{} = context),
    do: %AST.PatErr{pattern: lower_semantic_pat(pattern, context)}

  def lower_semantic_pat({:{}, _, [:ok, pattern]}, %Context{} = context),
    do: %AST.PatOk{pattern: lower_semantic_pat(pattern, context)}

  def lower_semantic_pat({:{}, _, [:error, pattern]}, %Context{} = context),
    do: %AST.PatErr{pattern: lower_semantic_pat(pattern, context)}

  def lower_semantic_pat({:tuple, _, [patterns]}, %Context{} = context),
    do: %AST.PatTuple{patterns: Enum.map(patterns, &lower_semantic_pat(&1, context))}

  def lower_semantic_pat({:path_tuple, _, [path, patterns]}, %Context{} = context),
    do: %AST.PatPathTuple{
      path: lower_expr_path(path, context),
      patterns: Enum.map(patterns, &lower_semantic_pat(&1, context))
    }

  def lower_semantic_pat({:struct, _, [path, fields]}, %Context{} = context),
    do: %AST.PatStruct{
      path: lower_expr_path(path, context),
      fields: lower_semantic_pat_fields(fields, context)
    }

  def lower_semantic_pat(nil, %Context{}), do: %AST.PatNone{}

  def lower_semantic_pat(:_, %Context{}), do: %AST.PatWildcard{}

  def lower_semantic_pat({:_, _, _}, %Context{}), do: %AST.PatWildcard{}

  def lower_semantic_pat(other, %Context{} = context),
    do: lower_match_pattern(other, nil, context)

  defp lower_semantic_pat_fields(fields, %Context{} = context) when is_list(fields) do
    Enum.map(fields, fn {name, pattern} -> {name, lower_semantic_pat(pattern, context)} end)
  end

  defp lower_expr_path(%AST.Path{} = path, %Context{}), do: path

  defp lower_expr_path(expression, %Context{} = context) do
    case Lower.lower_expr(expression, context) do
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

  @doc "The atom a pattern names, or a diagnostic for one it cannot."
  def semantic_atom!(atom) when is_atom(atom), do: atom

  def semantic_atom!({name, _, context}) when is_atom(name) and is_atom(context), do: name

  def semantic_atom!(other) do
    Diagnostic.lower(:expected_atom_identifier, other, "expected atom identifier")
  end

  @doc "`context` with the variables a binding pattern binds shadowing any of the same name."
  def context_with_lexical_pattern_vars(pattern, %Context{} = context) do
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

  @doc "The variables `pattern` binds."
  def binding_pattern_names({name, _meta, ast_context})
      when is_atom(name) and is_atom(ast_context) and name != :_,
      do: [name]

  def binding_pattern_names(pattern) do
    case ElixirPattern.tuple_elements(pattern) do
      elements when is_list(elements) -> Enum.flat_map(elements, &binding_pattern_names/1)
      _not_tuple -> []
    end
  end

  @doc "The variables a clause body changes among those its pattern binds."
  def collect_pattern_mutations(term, context) do
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

  @doc "The variables `ast` borrows `mut`."
  def collect_mut_refs(term) do
    Walk.reduce(term, [], fn
      %AST.Ref{mutable: true, expr: %AST.Var{name: name}}, acc -> [name | acc]
      _other, acc -> acc
    end)
  end
end
