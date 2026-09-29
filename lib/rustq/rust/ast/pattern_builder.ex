defmodule RustQ.Rust.AST.PatternBuilder do
  @moduledoc """
  Constructors and normalization for Rust pattern AST nodes.

  `pattern/1` accepts existing pattern nodes and atom variables. Named helpers
  cover wildcard, literal, path, tuple-variant, struct, slice, `Some`, `Ok`, and
  `Err` patterns.
  """

  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A

  def pattern(%{__struct__: _module} = value) do
    if AST.pat_node?(value) do
      value
    else
      raise ArgumentError, "expected RustQ pattern AST node, got: #{inspect(value)}"
    end
  end

  def pattern(name) when is_atom(name), do: var(name)

  def var(name) when is_atom(name), do: %AST.PatVar{name: name}
  def wildcard, do: %AST.PatWildcard{}
  def path(path), do: %AST.PatPath{path: A.expr_path(path)}
  def lit(value), do: %AST.PatLiteral{value: value}
  def none, do: %AST.PatNone{}
  def some(pattern), do: %AST.PatSome{pattern: pattern(pattern)}
  def ok(pattern), do: %AST.PatOk{pattern: pattern(pattern)}
  def err(pattern), do: %AST.PatErr{pattern: pattern(pattern)}

  def tuple(patterns), do: %AST.PatTuple{patterns: Enum.map(patterns, &pattern/1)}

  def path_tuple(path, patterns),
    do: %AST.PatPathTuple{path: A.expr_path(path), patterns: Enum.map(patterns, &pattern/1)}

  def slice(patterns, opts \\ []) do
    %AST.PatSlice{
      patterns: Enum.map(patterns, &pattern/1),
      rest: opts |> Keyword.get(:rest) |> then(&if(&1, do: pattern(&1)))
    }
  end

  def struct(path, fields) do
    %AST.PatStruct{
      path: A.expr_path(path),
      fields: Enum.map(fields, fn {name, pattern} -> {name, pattern(pattern)} end)
    }
  end
end
