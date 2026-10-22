defmodule RustQ.Reach.Smells.RawRustEscape do
  @moduledoc """
  Reach smell check flagging a literal raw Rust escape that spans lines or exceeds 100
  characters, which `defrust`, RustQ AST builders, metadata, or a small `defrustmacro`
  usually express.
  """

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @kind :rustq_large_raw_rust_escape
  @max_inline_chars 100

  @impl true
  def kinds, do: [@kind]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, findings ->
        {node, raw_escape_findings(node, file) ++ findings}
      end)

    Enum.reverse(findings)
  end

  defp raw_escape_findings(node, file) do
    with {:ok, meta, source} <- raw_escape(node),
         true <- large_escape?(source) do
      [
        Finding.new(
          kind: @kind,
          message:
            "large raw Rust escape; prefer defrust, RustQ AST/builders, metadata, or a small defrustmacro",
          location: location(file, meta),
          evidence: String.slice(source, 0, 120)
        )
      ]
    else
      _not_raw_or_small -> []
    end
  end

  defp raw_escape({name, meta, [source]})
       when name in [:raw_expr!, :raw_pat!, :raw_stmt!, :raw_arm!] do
    with {:ok, source} <- string_literal(source), do: {:ok, meta, source}
  end

  defp raw_escape({{:., meta, [_receiver, :fragment]}, _call_meta, [_kind, source]}) do
    with {:ok, source} <- string_literal(source), do: {:ok, meta, source}
  end

  defp raw_escape({{:., meta, [_receiver, function]}, _call_meta, [source]})
       when function in [:raw, :item, :impl_item, :stmt, :expr, :arm, :macro_item] do
    with {:ok, source} <- string_literal(source), do: {:ok, meta, source}
  end

  defp raw_escape(_node), do: :error

  defp string_literal(source) when is_binary(source), do: {:ok, source}
  defp string_literal({:__block__, _meta, [source]}) when is_binary(source), do: {:ok, source}
  defp string_literal(_source), do: :error

  defp large_escape?(source) do
    String.contains?(source, "\n") or String.length(source) > @max_inline_chars
  end

  defp location(file, meta), do: "#{file}:#{meta[:line] || 0}"
end
