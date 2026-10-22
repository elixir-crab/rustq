defmodule RustQ.Reach.Smells.LowLevelControlFlow do
  @moduledoc """
  Reach smell check flagging `return!`, `break`, or `continue` in a `defrust` body, where
  ordinary Rusty-Elixir control flow usually says the same thing.
  """

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @kind :rustq_low_level_control_flow
  @low_level_forms [:return!, :break, :continue]

  @impl true
  def kinds, do: [@kind]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:defrust, _meta, [_call_ast, body_keyword]} = node, findings ->
          {node, defrust_findings(do_body(body_keyword), file) ++ findings}

        node, findings ->
          {node, findings}
      end)

    Enum.reverse(findings)
  end

  defp do_body(do: body), do: body
  defp do_body([{_, body}]), do: body
  defp do_body(body), do: body

  defp defrust_findings(body, file) do
    {_body, findings} =
      Macro.prewalk(body, [], fn node, findings ->
        {node, control_flow_findings(node, file) ++ findings}
      end)

    findings
  end

  defp control_flow_findings({name, meta, args}, file)
       when name in @low_level_forms and is_list(args) do
    [
      Finding.new(
        kind: @kind,
        message:
          "#{name} in defrust body; prefer ordinary Rusty-Elixir control flow unless this is a low-level RustQ primitive",
        location: location(file, meta),
        evidence: Atom.to_string(name)
      )
    ]
  end

  defp control_flow_findings(_node, _file), do: []

  defp location(file, meta), do: "#{file}:#{meta[:line] || 0}"
end
