defmodule RustQ.Binding.Substitution do
  @moduledoc """
  Structural substitution for explicitly declared Rust type parameters.

  Parameter names must come from declarations, never capitalization guesses.
  This does not solve trait bounds or associated-type projections.
  """

  import Kernel, except: [apply: 2]

  alias RustQ.Meta.Type
  alias RustQ.Rust
  alias RustQ.Rust.AST

  @doc "Unifies formal and actual type ASTs, returning bindings or a conflict."
  def infer(formal, actual, parameters, bindings \\ %{}) do
    unify(formal, actual, MapSet.new(parameters, &to_string/1), bindings)
  end

  @doc "Substitutes known parameters throughout a normalized type and its metadata."
  def apply(%Type{} = type, bindings) do
    metadata = replace(type.meta, bindings)

    if match?(%AST.TypeImplTrait{callable: nil}, type.ast) and metadata != type.meta do
      raise ArgumentError, "cannot specialize opaque foreign trait bounds consistently"
    end

    ast = replace(type.ast, bindings)

    if ast != type.ast and parameter_leaf?(type.ast, bindings) do
      Type.ast_type(ast)
    else
      %{type | ast: ast, rust: Rust.render_type(ast), meta: metadata}
    end
  end

  defp unify(
         %AST.TypePath{parts: [name], generics: [], lifetimes: []} = formal,
         actual,
         parameters,
         bindings
       ) do
    if MapSet.member?(parameters, to_string(name)) do
      case Map.fetch(bindings, to_string(name)) do
        :error -> {:ok, Map.put(bindings, to_string(name), actual)}
        {:ok, ^actual} -> {:ok, bindings}
        {:ok, previous} -> {:error, {:conflict, to_string(name), previous, actual}}
      end
    else
      identical(formal, actual, bindings)
    end
  end

  defp unify(
         %AST.TypeRef{inner: formal, mutable: mutable},
         %AST.TypeRef{inner: actual, mutable: mutable},
         parameters,
         bindings
       ),
       do: unify(formal, actual, parameters, bindings)

  defp unify(
         %AST.TypePath{parts: parts, generics: formal, lifetimes: lifetimes},
         %AST.TypePath{parts: parts, generics: actual, lifetimes: lifetimes},
         parameters,
         bindings
       ),
       do: unify_list(formal, actual, parameters, bindings)

  defp unify(formal, actual, _parameters, bindings), do: identical(formal, actual, bindings)

  defp unify_list([], [], _parameters, bindings), do: {:ok, bindings}

  defp unify_list([formal | rest], [actual | tail], parameters, bindings) do
    with {:ok, bindings} <- unify(formal, actual, parameters, bindings),
         do: unify_list(rest, tail, parameters, bindings)
  end

  defp unify_list(formal, actual, _parameters, _bindings),
    do: {:error, {:mismatch, formal, actual}}

  defp identical(type, type, bindings), do: {:ok, bindings}
  defp identical(formal, actual, _bindings), do: {:error, {:mismatch, formal, actual}}

  defp parameter_leaf?(%AST.TypePath{parts: [name], generics: [], lifetimes: []}, bindings),
    do: Map.has_key?(bindings, to_string(name))

  defp parameter_leaf?(_ast, _bindings), do: false

  defp replace(%Type{} = type, bindings), do: apply(type, bindings)

  defp replace(%AST.TypePath{parts: [name], generics: [], lifetimes: []} = type, bindings),
    do: Map.get(bindings, to_string(name), type)

  defp replace(%module{} = value, bindings),
    do:
      struct(
        module,
        Map.new(Map.from_struct(value), fn {key, value} -> {key, replace(value, bindings)} end)
      )

  defp replace(value, bindings) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, replace(value, bindings)} end)

  defp replace(value, bindings) when is_list(value), do: Enum.map(value, &replace(&1, bindings))

  defp replace(value, bindings) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&replace(&1, bindings)) |> List.to_tuple()

  defp replace(value, _bindings), do: value
end
