defmodule RustQ.Corpus do
  @moduledoc """
  The golden lowering corpus under `test/corpus`: each `.exs` case defines `RustQ.Meta`
  modules whose rendered Rust is checked against the `.rs` file beside it. Backs the
  `rustq.corpus` Mix task, which checks, updates, and reports coverage of the cases.
  """

  @root Path.expand("../../test/corpus", __DIR__)
  @lower_path Path.expand("meta/lower.ex", __DIR__)

  @spec cases(Path.t()) :: [Path.t()]
  def cases(root \\ @root) do
    root
    |> Path.join("**/*.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec expected_path(Path.t()) :: Path.t()
  def expected_path(source_path) do
    Path.rootname(source_path) <> ".rs"
  end

  @spec render_file!(Path.t(), keyword()) :: String.t()
  def render_file!(source_path, opts \\ []) do
    modules =
      source_path
      |> Code.require_file()
      |> required_modules(source_path)
      |> Enum.filter(&function_exported?(&1, :__rustq_source__, 0))
      |> Enum.sort_by(&Atom.to_string/1)

    if modules == [] do
      raise ArgumentError, "corpus file #{source_path} did not define a RustQ.Meta module"
    end

    modules
    |> Enum.map_join("\n", &render_module!/1)
    |> maybe_format_rust(Keyword.get(opts, :rustfmt, true), source_path)
  end

  defp required_modules(modules, source_path) when modules in [nil, []],
    do: source_modules(source_path)

  defp required_modules(modules, _source_path), do: Enum.map(modules, &elem(&1, 0))

  defp source_modules(source_path) do
    source_path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, modules ->
        {node, [Module.concat(parts) | modules]}

      node, modules ->
        {node, modules}
    end)
    |> elem(1)
  end

  @spec stale_cases(Path.t()) :: [{Path.t(), String.t(), String.t()}]
  def stale_cases(root \\ @root) do
    for source_path <- cases(root),
        expected = expected_path(source_path),
        actual = render_file!(source_path),
        expected_source = if(File.exists?(expected), do: File.read!(expected), else: ""),
        actual != expected_source do
      {source_path, expected_source, actual}
    end
  end

  @spec update!(Path.t()) :: [Path.t()]
  def update!(root \\ @root) do
    for source_path <- cases(root) do
      expected = expected_path(source_path)
      File.mkdir_p!(Path.dirname(expected))
      File.write!(expected, render_file!(source_path))
      expected
    end
  end

  @spec coverage(Path.t()) :: map()
  def coverage(root \\ @root) do
    case_paths = cases(root)
    categories = Enum.frequencies_by(case_paths, &corpus_category(root, &1))

    %{
      case_count: length(case_paths),
      categories: categories,
      unsupported_diagnostics: unsupported_diagnostics()
    }
  end

  @spec unsupported_diagnostics(Path.t()) :: [atom()]
  def unsupported_diagnostics(lower_path \\ @lower_path) do
    lower_path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> then(fn ast ->
      {_ast, codes} =
        Macro.prewalk(ast, [], fn
          {{:., _, [{:__aliases__, _, [:Diagnostic]}, :lower]}, _, [code | _]} = node, acc
          when is_atom(code) ->
            {node, [code | acc]}

          node, acc ->
            {node, acc}
        end)

      codes
      |> Enum.filter(&(Atom.to_string(&1) |> String.starts_with?("unsupported")))
      |> Enum.uniq()
      |> Enum.sort()
    end)
  end

  defp corpus_category(root, source_path) do
    source_path
    |> Path.relative_to(root)
    |> Path.split()
    |> List.first()
  end

  defp render_module!(module) do
    if function_exported?(module, :__rustq_corpus_fragments__, 0) do
      module.__rustq_corpus_fragments__()
      |> Enum.map_join("\n", &RustQ.Rust.to_fragment/1)
    else
      module.__rustq_source__()
    end
  end

  defp maybe_format_rust(source, false, _source_path), do: source

  defp maybe_format_rust(source, true, source_path) do
    path = Path.join(System.tmp_dir!(), "rustq-corpus-#{System.unique_integer([:positive])}.rs")
    File.write!(path, source)

    try do
      case System.cmd("rustfmt", ["--edition", "2021", path], stderr_to_stdout: true) do
        {_output, 0} -> File.read!(path)
        {output, _status} -> raise "rustfmt failed for #{source_path}:\n#{output}"
      end
    after
      File.rm(path)
    end
  end
end
