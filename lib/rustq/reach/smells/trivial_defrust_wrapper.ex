defmodule RustQ.Reach.Smells.TrivialDefrustWrapper do
  @moduledoc """
  Reach smell check flagging a `defrust` that only calls one function and returns `:ok`, a
  wrapper callable metadata and inference make unnecessary.
  """

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @kind :rustq_trivial_defrust_wrapper

  @impl true
  def kinds, do: [@kind]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:defrust, _meta, [call_ast, body_keyword]} = node, findings ->
          {node, trivial_wrapper_findings(call_ast, do_body(body_keyword), file) ++ findings}

        node, findings ->
          {node, findings}
      end)

    Enum.reverse(findings)
  end

  defp do_body(do: body), do: body
  defp do_body([{_, body}]), do: body
  defp do_body(body), do: body

  defp trivial_wrapper_findings(call_ast, body, file) do
    expressions = block_expressions(body)

    if trivial_wrapper_body?(expressions) do
      [
        Finding.new(
          kind: @kind,
          message:
            "defrust #{function_name(call_ast)} only wraps one call and returns :ok; prefer callable metadata/inference over trivial wrappers",
          location: location(file, call_meta(call_ast))
        )
      ]
    else
      []
    end
  end

  defp trivial_wrapper_body?([call, :ok]), do: wrapper_call?(call)
  defp trivial_wrapper_body?([{:=, _meta, [_pattern, call]}, :ok]), do: wrapper_call?(call)
  defp trivial_wrapper_body?(_expressions), do: false

  defp wrapper_call?({:unwrap!, _meta, [call]}), do: wrapper_call?(call)

  defp wrapper_call?({{:., _meta, [_receiver, _function]}, _call_meta, args}) when is_list(args),
    do: true

  defp wrapper_call?({_name, _meta, args}) when is_list(args), do: true
  defp wrapper_call?(_node), do: false

  defp block_expressions({:__block__, _meta, expressions}),
    do: Enum.map(expressions, &unwrap_sourceror_atom_block/1)

  defp block_expressions(expression), do: [unwrap_sourceror_atom_block(expression)]

  defp unwrap_sourceror_atom_block({:__block__, _meta, [atom]}) when is_atom(atom), do: atom
  defp unwrap_sourceror_atom_block(expression), do: expression

  defp function_name({name, _meta, args}) when is_atom(name) and is_list(args),
    do: "#{name}/#{length(args)}"

  defp function_name(_call_ast), do: "function"

  defp call_meta({_name, meta, _args}) when is_list(meta), do: meta
  defp call_meta(_call_ast), do: []

  defp location(file, meta), do: "#{file}:#{meta[:line] || 0}"
end
