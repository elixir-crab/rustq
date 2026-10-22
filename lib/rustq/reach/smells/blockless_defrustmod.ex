defmodule RustQ.Reach.Smells.BlocklessDefrustmod do
  @moduledoc """
  Reach smell check flagging a `defrustmod` without a `do` block, which mirrors an external
  Rust module; remote types and calls, or a block-form `defrustmod` for a RustQ-owned module,
  say the same thing directly.
  """

  use Reach.Smell.Check.AST

  alias Reach.Smell.Finding

  @kind :rustq_blockless_defrustmod

  @impl true
  def kinds, do: [@kind]

  defp scan_ast(ast, file) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, findings ->
        {node, defrustmod_findings(node, file) ++ findings}
      end)

    Enum.reverse(findings)
  end

  defp defrustmod_findings({:defrustmod, meta, [alias_ast | _rest] = args}, file)
       when is_list(args) do
    if not rust_module_alias?(alias_ast) or block_form?(args) do
      []
    else
      [
        Finding.new(
          kind: @kind,
          message:
            "blockless defrustmod can mirror an external Rust module; prefer remote types/calls or block-form defrustmod for RustQ-owned modules",
          location: location(file, meta)
        )
      ]
    end
  end

  defp defrustmod_findings(_node, _file), do: []

  defp rust_module_alias?({:__aliases__, _meta, _parts}), do: true
  defp rust_module_alias?(atom) when is_atom(atom), do: true
  defp rust_module_alias?(_alias_ast), do: false

  defp block_form?([_alias_ast, opts]) when is_list(opts), do: do_keyword?(opts)
  defp block_form?([_alias_ast, _opts, opts]) when is_list(opts), do: do_keyword?(opts)
  defp block_form?(_args), do: false

  defp do_keyword?(opts), do: Enum.any?(opts, &do_keyword_entry?/1)
  defp do_keyword_entry?({:do, _body}), do: true
  defp do_keyword_entry?({{:__block__, _meta, [:do]}, _body}), do: true
  defp do_keyword_entry?(_entry), do: false

  defp location(file, meta), do: "#{file}:#{meta[:line] || 0}"
end
