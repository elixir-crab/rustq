defmodule RustQ.Reach.Smells.DefrustMissingSpec do
  @moduledoc """
  Reach smell check flagging a `defrust` without a `@spec`, which RustQ needs for the Rust
  signature, typed lowering, and inference.
  """

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @kind :rustq_defrust_missing_spec

  @impl true
  def kinds, do: [@kind]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:__block__, _meta, expressions} = node, findings ->
          {node, block_findings(expressions, file) ++ findings}

        {:defmodule, _meta, [_name, [do: body]]} = node, findings ->
          {node, block_findings(block_expressions(body), file) ++ findings}

        node, findings ->
          {node, findings}
      end)

    Enum.reverse(findings)
  end

  defp block_findings(expressions, file) do
    {_pending_specs, findings} =
      Enum.reduce(expressions, {MapSet.new(), []}, &reduce_expression(&1, &2, file))

    Enum.reverse(findings)
  end

  defp reduce_expression(expression, state, file) do
    case spec_signature(expression) do
      {name, arity} -> add_spec({name, arity}, state)
      nil -> reduce_defrust_expression(expression, state, file)
    end
  end

  defp add_spec(key, {pending_specs, findings}), do: {MapSet.put(pending_specs, key), findings}

  defp reduce_defrust_expression(expression, {pending_specs, findings}, file) do
    case defrust_signature(expression) do
      {name, arity, meta} -> reduce_defrust({name, arity}, meta, pending_specs, findings, file)
      nil -> {pending_specs, findings}
    end
  end

  defp reduce_defrust(key, meta, pending_specs, findings, file) do
    if MapSet.member?(pending_specs, key) do
      {MapSet.delete(pending_specs, key), findings}
    else
      {pending_specs, [missing_spec_finding(file, meta, key) | findings]}
    end
  end

  defp spec_signature({:@, _meta, [{:spec, _spec_meta, [{:"::", _, [call, _return]}]}]}),
    do: call_signature(call)

  defp spec_signature(_expression), do: nil

  defp defrust_signature({:defrust, meta, [call, _body_keyword]}) do
    with {name, arity} <- call_signature(call), do: {name, arity, meta}
  end

  defp defrust_signature(_expression), do: nil

  defp call_signature({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp call_signature(_call), do: nil

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp missing_spec_finding(file, meta, {name, arity}) do
    Finding.new(
      kind: @kind,
      message:
        "defrust #{name}/#{arity} has no @spec; RustQ needs specs for typed lowering and inference",
      location: "#{file}:#{meta[:line] || 0}",
      evidence: "defrust #{name}/#{arity}"
    )
  end
end
