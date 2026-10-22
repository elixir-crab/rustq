defmodule RustQ.Reach.Smells.DynamicRawRustEscape do
  @moduledoc """
  Reach smell check flagging a raw Rust escape (`raw_expr!`, `raw_pat!`, `raw_stmt!`,
  `raw_arm!`, or an AST `raw`, `escape_expr`, or `macro_item`) built from a non-literal value,
  which the parser cannot validate where it is written.
  """

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @kind :rustq_dynamic_raw_rust_escape
  @raw_functions [:raw_expr!, :raw_pat!, :raw_stmt!, :raw_arm!]
  @raw_methods [:raw, :escape_expr, :macro_item]

  @impl true
  def kinds, do: [@kind]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, findings ->
        {node, dynamic_escape_findings(node, file) ++ findings}
      end)

    Enum.reverse(findings)
  end

  defp dynamic_escape_findings(node, file) do
    with {:ok, meta, source} <- raw_escape(node),
         false <- literal_source?(source) do
      [
        Finding.new(
          kind: @kind,
          message:
            "dynamic raw Rust escape; use RustQ AST, defrust, or a literal parser-validated escape",
          location: "#{file}:#{meta[:line] || 0}",
          evidence: Macro.to_string(source)
        )
      ]
    else
      _literal_or_not_escape -> []
    end
  end

  defp raw_escape({name, meta, [source]}) when name in @raw_functions, do: {:ok, meta, source}

  defp raw_escape({{:., meta, [_receiver, :fragment]}, _call_meta, [_kind, source]}),
    do: {:ok, meta, source}

  defp raw_escape({{:., meta, [_receiver, function]}, _call_meta, [source]})
       when function in @raw_methods,
       do: {:ok, meta, source}

  defp raw_escape(_node), do: :error

  defp literal_source?(source) when is_binary(source) or is_atom(source), do: true

  defp literal_source?({:__block__, _meta, [source]}) when is_binary(source) or is_atom(source),
    do: true

  defp literal_source?(_source), do: false
end
