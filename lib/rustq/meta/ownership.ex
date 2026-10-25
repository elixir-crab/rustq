defmodule RustQ.Meta.Ownership do
  @moduledoc """
  Which uses of a variable in a Rusty-Elixir body are its last, so lowering knows where Rust
  may take a value and where it must borrow or copy one.

  Elixir never changes a value, so a list, map, or set passed to a function is still there
  for every later use. Rust code taking the value ends it, so lowering takes one only at its
  last use. `annotate/1` walks a body backwards, as liveness is computed, and records on each
  variable occurrence the variables still in use after it:

    * expressions, arguments, and pipes run in order;
    * the branches of `case`, `if`, `cond`, and `with` are alternatives;
    * a closure or comprehension body may run many times, so no use inside one is the last;
    * rebinding a name ends the value it had.

  A value built from another, as `by_id = index(records)`, may borrow from it, so the other
  stays in use while the built value does; `in_use?/3` asks.
  """

  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  @live :rustq_live_after

  @typedoc "A set of variable names."
  @type names :: %{optional(atom()) => true}

  @typedoc "The variables each binding was built from, by name."
  @type built_from :: %{optional(atom()) => names()}

  @doc """
  Annotates every variable occurrence in `body` with the variables in use after it, and
  returns what each binding was built from.
  """
  @spec annotate(Macro.t()) :: {Macro.t(), built_from()}
  def annotate(body) do
    {annotated, _live_in} = live(body, %{})
    {annotated, built_from(body)}
  end

  @doc """
  Whether the variable occurrence `variable` is not the last use of its value: a later use
  follows, it is inside a body that may run again, or a value still in use was built from it
  and, by its type in `vars`, may borrow from it. An occurrence lowering made itself, without
  an annotation, is a fresh value's only use.
  """
  @spec in_use?(Macro.t(), built_from(), %{optional(atom()) => Type.t()}) :: boolean()
  def in_use?({name, meta, _context}, built_from, vars) when is_atom(name) do
    case Keyword.get(meta, @live) do
      nil ->
        false

      live_after ->
        member?(live_after, name) or
          Enum.any?(Map.keys(live_after), &member?(sources(&1, built_from, vars), name))
    end
  end

  def in_use?(_variable, _built_from, _vars), do: false

  # Backwards liveness: `live(ast, live_out)` annotates `ast` and returns the variables in
  # use before it.
  defp live({name, meta, context}, live_out) when is_atom(name) and is_atom(context) do
    if variable?(name),
      do: {{name, Keyword.put(meta, @live, live_out), context}, put(live_out, name)},
      else: {{name, meta, context}, live_out}
  end

  defp live({:=, meta, [pattern, expression]}, live_out) do
    after_binding = difference(live_out, bound(pattern))
    {pattern, pinned} = live_pins(pattern, after_binding)
    {expression, live_in} = live(expression, pinned)
    {{:=, meta, [pattern, expression]}, live_in}
  end

  defp live({:__block__, meta, expressions}, live_out) do
    {expressions, live_in} = live_sequence(expressions, live_out)
    {{:__block__, meta, expressions}, live_in}
  end

  # A closure may run many times, so what it captures stays in use throughout its body, while
  # its own variables follow the body. What is live at the start of its body, with nothing in
  # use after it, is what it captures.
  defp live({:fn, meta, clauses}, live_out) do
    {_clauses, captured} = live_clauses(clauses, %{})
    {clauses, _clauses_live} = live_clauses(clauses, captured)
    {{:fn, meta, clauses}, union(live_out, captured)}
  end

  defp live({:&, meta, [body]}, live_out) when not is_integer(body) do
    {_body, captured} = live(body, %{})
    {body, _body_live} = live(body, captured)
    {{:&, meta, [body]}, union(live_out, captured)}
  end

  defp live({:case, meta, [scrutinee, [do: clauses]]}, live_out) when is_list(clauses) do
    {clauses, branches} = live_clauses(clauses, live_out)
    {scrutinee, live_in} = live(scrutinee, branches)
    {{:case, meta, [scrutinee, [do: clauses]]}, live_in}
  end

  defp live({:if, meta, [condition, branches]}, live_out) when is_list(branches) do
    {branches, branch_live} =
      Enum.map_reduce(branches, %{}, fn {key, branch}, union ->
        {branch, branch_live} = live(branch, live_out)
        {{key, branch}, union(union, branch_live)}
      end)

    # A missing `else` does nothing, so what is in use after the `if` stays in use.
    branch_live =
      if Keyword.has_key?(branches, :else),
        do: branch_live,
        else: union(branch_live, live_out)

    {condition, live_in} = live(condition, branch_live)
    {{:if, meta, [condition, branches]}, live_in}
  end

  defp live({:with, meta, args}, live_out) do
    {clauses, [options]} = Enum.split(args, -1)
    {body, body_live} = live(Keyword.fetch!(options, :do), live_out)

    {else_clauses, else_live} =
      case Keyword.get(options, :else) do
        nil -> {nil, live_out}
        clauses -> live_clauses(clauses, live_out)
      end

    {clauses, live_in} = live_with_clauses(clauses, union(body_live, else_live))
    options = Keyword.replace!(options, :do, body)
    options = if else_clauses, do: Keyword.replace!(options, :else, else_clauses), else: options
    {{:with, meta, clauses ++ [options]}, live_in}
  end

  # A comprehension evaluates its first collection once; the rest may run for every item, so
  # what it captures stays in use throughout.
  defp live({:for, meta, [{:<-, generator_meta, [pattern, collection]} | rest]}, live_out) do
    {_rest, region_live} = live_comprehension(rest, %{})
    captured = difference(region_live, bound(pattern))
    {rest, _rest_live} = live_comprehension(rest, captured)
    {collection, live_in} = live(collection, union(live_out, captured))
    {{:for, meta, [{:<-, generator_meta, [pattern, collection]} | rest]}, live_in}
  end

  # A `cond` tests its conditions in order until one holds, and runs that clause's body.
  defp live({:cond, meta, [[do: clauses]]}, live_out) do
    {reversed, live_in} =
      clauses
      |> Enum.reverse()
      |> Enum.map_reduce(%{}, fn {:->, clause_meta, [[condition], body]}, later ->
        {body, body_live} = live(body, live_out)
        {condition, live_in} = live(condition, union(body_live, later))
        {{:->, clause_meta, [[condition], body]}, live_in}
      end)

    {{:cond, meta, [[do: Enum.reverse(reversed)]]}, live_in}
  end

  defp live({:^, meta, [variable]}, live_out) do
    {variable, live_in} = live(variable, live_out)
    {{:^, meta, [variable]}, live_in}
  end

  defp live({:__aliases__, _meta, _parts} = alias, live_out), do: {alias, live_out}

  # A call runs its receiver, then its arguments, in order; a pipe runs its left side first.
  defp live({{:., dot_meta, [receiver, function]}, meta, args}, live_out) when is_list(args) do
    {[receiver | args], live_in} = live_sequence([receiver | args], live_out)
    {{{:., dot_meta, [receiver, function]}, meta, args}, live_in}
  end

  defp live({form, meta, args}, live_out) when is_list(args) do
    {args, live_in} = live_sequence(args, live_out)
    {{form, meta, args}, live_in}
  end

  defp live({left, right}, live_out) do
    {[left, right], live_in} = live_sequence([left, right], live_out)
    {{left, right}, live_in}
  end

  defp live(list, live_out) when is_list(list), do: live_sequence(list, live_out)
  defp live(other, live_out), do: {other, live_out}

  defp live_sequence(expressions, live_out) do
    expressions
    |> Enum.reverse()
    |> Enum.map_reduce(live_out, &live/2)
    |> then(fn {reversed, live_in} -> {Enum.reverse(reversed), live_in} end)
  end

  # Each clause binds its pattern's variables for its body; the clauses are alternatives.
  defp live_clauses(clauses, live_out) when is_list(clauses) do
    Enum.map_reduce(clauses, %{}, fn {:->, meta, [heads, body]}, union ->
      heads = List.wrap(heads)
      {body, body_live} = live(body, live_out)
      {heads, head_live} = live_heads(heads, body_live)
      {{:->, meta, [heads, body]}, union(union, head_live)}
    end)
  end

  # `fn a, b when guard ->` puts its patterns and guard in one `when`.
  defp live_heads([{:when, meta, patterns_and_guard}], body_live) do
    {patterns, [guard]} = Enum.split(patterns_and_guard, -1)
    {guard, guard_live} = live(guard, body_live)
    {patterns, live_in} = live_patterns(patterns, guard_live)
    {[{:when, meta, patterns ++ [guard]}], live_in}
  end

  defp live_heads(patterns, body_live), do: live_patterns(patterns, body_live)

  defp live_patterns(patterns, live_out) do
    bound = Enum.reduce(patterns, %{}, &union(&2, bound(&1)))
    live_pins(patterns, difference(live_out, bound))
  end

  # A comprehension's qualifiers and option lists after its first generator: each generator
  # binds its pattern for the qualifiers and body after it. The option lists keep their shape,
  # as `for x <- xs, reduce: acc do ... end` writes two.
  defp live_comprehension(rest, live_out) do
    {qualifiers, option_lists} = Enum.split_while(rest, &(not Keyword.keyword?(&1) or &1 == []))
    {option_lists, body_live} = live_options(option_lists, live_out, &live_body_option/2)
    {qualifiers, qualifiers_live} = live_qualifiers(qualifiers, body_live)
    {option_lists, live_in} = live_options(option_lists, qualifiers_live, &live_other_option/2)
    {qualifiers ++ option_lists, live_in}
  end

  defp live_options(option_lists, live_out, live_option) do
    option_lists
    |> Enum.reverse()
    |> Enum.map_reduce(live_out, fn options, live ->
      {reversed, live} = options |> Enum.reverse() |> Enum.map_reduce(live, live_option)
      {Enum.reverse(reversed), live}
    end)
    |> then(fn {reversed, live} -> {Enum.reverse(reversed), live} end)
  end

  defp live_body_option({:do, [{:->, _meta, _clause} | _] = clauses}, live) do
    {clauses, live} = live_clauses(clauses, live)
    {{:do, clauses}, live}
  end

  defp live_body_option({:do, body}, live) do
    {body, live} = live(body, live)
    {{:do, body}, live}
  end

  defp live_body_option(option, live), do: {option, live}

  defp live_other_option({:do, _body} = option, live), do: {option, live}

  defp live_other_option({key, value}, live) do
    {value, live} = live(value, live)
    {{key, value}, live}
  end

  defp live_qualifiers(qualifiers, live_out) do
    qualifiers
    |> Enum.reverse()
    |> Enum.map_reduce(live_out, fn
      {:<-, meta, [pattern, collection]}, live ->
        live_generator(meta, pattern, collection, live)

      filter, live ->
        live(filter, live)
    end)
    |> then(fn {reversed, live} -> {Enum.reverse(reversed), live} end)
  end

  defp live_with_clauses(clauses, live_out) do
    clauses
    |> Enum.reverse()
    |> Enum.map_reduce(live_out, fn
      {:<-, meta, [pattern, expression]}, live ->
        live_generator(meta, pattern, expression, live)

      expression, live ->
        live(expression, live)
    end)
    |> then(fn {reversed, live_in} -> {Enum.reverse(reversed), live_in} end)
  end

  # `pattern <- expression` binds the pattern's variables for what follows it.
  defp live_generator(meta, pattern, expression, live) do
    {pattern, pinned} = live_pins(pattern, difference(live, bound(pattern)))
    {expression, live_in} = live(expression, pinned)
    {{:<-, meta, [pattern, expression]}, live_in}
  end

  # A pinned variable in a pattern is a use of it.
  defp live_pins(pattern, live_out) do
    Macro.prewalk(pattern, live_out, fn
      {:^, meta, [{name, variable_meta, context}]}, live
      when is_atom(name) and is_atom(context) ->
        {{:^, meta, [{name, Keyword.put(variable_meta, @live, live), context}]}, put(live, name)}

      node, live ->
        {node, live}
    end)
  end

  defp bound(pattern) do
    pattern
    |> Macro.prewalk(%{}, fn
      {:^, _meta, [_pinned]}, names ->
        {:pinned, names}

      {name, _meta, context} = node, names when is_atom(name) and is_atom(context) ->
        {node, if(variable?(name), do: put(names, name), else: names)}

      node, names ->
        {node, names}
    end)
    |> elem(1)
  end

  defp free_variables(ast) do
    ast
    |> Macro.prewalk(%{}, fn
      {name, _meta, context} = node, names when is_atom(name) and is_atom(context) ->
        {node, if(variable?(name), do: put(names, name), else: names)}

      node, names ->
        {node, names}
    end)
    |> elem(1)
  end

  defp variable?(name), do: name not in [:_, :__MODULE__, :__CALLER__, :__ENV__, :__DIR__]

  # Each binding's name and the variables its expression uses; a later binding of a name
  # replaces an earlier one.
  defp built_from(body) do
    body
    |> Macro.prewalk(%{}, fn
      {:=, _meta, [pattern, expression]} = node, built_from ->
        from = free_variables(expression)

        {node,
         pattern |> bound() |> Map.keys() |> Enum.reduce(built_from, &Map.put(&2, &1, from))}

      node, built_from ->
        {node, built_from}
    end)
    |> elem(1)
  end

  # The variables a value may borrow from: those it was built from, and theirs, through values
  # whose types may hold a reference. A value of unknown type may.
  defp sources(name, built_from, vars), do: add_sources(name, built_from, vars, %{})

  defp add_sources(name, built_from, vars, found) do
    if may_borrow?(Map.get(vars, name)) do
      built_from
      |> Map.get(name, %{})
      |> Map.keys()
      |> Enum.reject(&member?(found, &1))
      |> Enum.reduce(found, fn source, found ->
        add_sources(source, built_from, vars, put(found, source))
      end)
    else
      found
    end
  end

  defp may_borrow?(%Type{kind: kind}) when kind in [:ref, :mut_ref, :slice], do: true
  defp may_borrow?(%Type{ast: ast}), do: borrowing_type?(ast)
  defp may_borrow?(_unknown), do: true

  defp borrowing_type?(%AST.TypeRef{}), do: true
  defp borrowing_type?(%AST.TypePath{lifetimes: [_ | _]}), do: true
  defp borrowing_type?(%AST.TypeRaw{}), do: true

  defp borrowing_type?(%_{} = type),
    do: type |> Map.from_struct() |> Enum.any?(fn {_field, value} -> borrowing_type?(value) end)

  defp borrowing_type?(types) when is_list(types), do: Enum.any?(types, &borrowing_type?/1)
  defp borrowing_type?(_other), do: false

  # Sets of names are maps to `true`, as `MapSet` is, without its opaque type.
  defp put(names, name), do: Map.put(names, name, true)
  defp member?(names, name), do: Map.has_key?(names, name)
  defp union(left, right), do: Map.merge(left, right)
  defp difference(left, right), do: Map.drop(left, Map.keys(right))
end
