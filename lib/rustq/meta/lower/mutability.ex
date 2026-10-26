defmodule RustQ.Meta.Lower.Mutability do
  @moduledoc """
  Which variables lowered Rust changes, so their bindings are `mut`: a `let` whose value a later
  statement changes in place, a closure argument its body changes, and an owned argument a
  rebinding updates in place, as `scores = Map.put(scores, name, 1)` becomes
  `scores.insert(name, 1);`.
  """

  alias RustQ.Meta.StdMethods
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.Walk

  @mutating_methods StdMethods.mutating()

  @doc """
  A binding of a collection to its update, `map = Map.put(map, key, value)`, as the in-place
  change of that collection, `map.insert(key, value);`, where the update takes the collection
  at its last use; any other statement unchanged.
  """
  @spec updated_in_place(AST.stmt()) :: AST.stmt()
  def updated_in_place(
        %AST.Let{
          pattern: %AST.PatVar{name: name},
          expr: %AST.BlockExpr{
            body: [
              %AST.Let{pattern: %AST.PatVar{name: :rustq_updated}, expr: %AST.Var{name: name}}
              | rest
            ]
          }
        } = let
      ) do
    case Enum.split(rest, -1) do
      {[_ | _] = updates, [%AST.Return{expr: %AST.Var{name: :rustq_updated}}]} ->
        case rename_var(updates, :rustq_updated, name) do
          [update] -> update
          updates -> A.stmt(A.block_expr(updates))
        end

      _other ->
        let
    end
  end

  def updated_in_place(statement), do: statement

  defp rename_var(%AST.Var{name: from}, from, to), do: A.var(to)

  defp rename_var(%module{} = node, from, to) do
    fields =
      node
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {key, rename_var(value, from, to)} end)

    struct(module, fields)
  end

  defp rename_var(values, from, to) when is_list(values),
    do: Enum.map(values, &rename_var(&1, from, to))

  defp rename_var(value, _from, _to), do: value

  @doc "Marks the variables of `pattern` in `mutable_vars` `mut`."
  @spec mark_mutable_pattern_vars(AST.pat(), MapSet.t(atom())) :: AST.pat()
  def mark_mutable_pattern_vars(%AST.PatVar{name: name} = pattern, mutable_vars) do
    if MapSet.member?(mutable_vars, name), do: %{pattern | mutable: true}, else: pattern
  end

  def mark_mutable_pattern_vars(%AST.PatSome{pattern: pattern} = some, mutable_vars),
    do: %{some | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

  def mark_mutable_pattern_vars(%AST.PatOk{pattern: pattern} = ok, mutable_vars),
    do: %{ok | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

  def mark_mutable_pattern_vars(%AST.PatErr{pattern: pattern} = err, mutable_vars),
    do: %{err | pattern: mark_mutable_pattern_vars(pattern, mutable_vars)}

  def mark_mutable_pattern_vars(%AST.PatTuple{patterns: patterns} = tuple, mutable_vars),
    do: %{tuple | patterns: Enum.map(patterns, &mark_mutable_pattern_vars(&1, mutable_vars))}

  def mark_mutable_pattern_vars(%AST.PatPathTuple{patterns: patterns} = tuple, mutable_vars),
    do: %{tuple | patterns: Enum.map(patterns, &mark_mutable_pattern_vars(&1, mutable_vars))}

  def mark_mutable_pattern_vars(%AST.PatStruct{fields: fields} = struct, mutable_vars) do
    fields =
      Enum.map(fields, fn {name, pattern} ->
        {name, mark_mutable_pattern_vars(pattern, mutable_vars)}
      end)

    %{struct | fields: fields}
  end

  def mark_mutable_pattern_vars(pattern, _mutable_vars), do: pattern

  @doc "Marks the `let`s and closure arguments of a lowered body that it changes `mut`."
  @spec infer_mutability([AST.stmt()]) :: [AST.stmt()]
  def infer_mutability(body) do
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

  @doc """
  The variables a lowered body changes in place through a statement calling a mutating
  method on them, as `scores.insert(name, 1);` does where `scores` was rebound to its update.
  """

  @spec mutated_variables([struct()]) :: MapSet.t(atom())
  def mutated_variables(body) do
    body
    |> Walk.reduce([], fn
      %AST.ExprStmt{expr: %AST.MethodCall{receiver: %AST.Var{name: name}, method: method}}, acc ->
        if mutating_method?(method), do: [name | acc], else: acc

      _node, acc ->
        acc
    end)
    |> MapSet.new()
  end

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
end
