defmodule RustQ.Spec do
  @moduledoc """
  Public helpers for lowering Elixir typespec forms into RustQ type metadata.

  `RustQ.Spec` accepts both ordinary quoted typespec AST and Erlang/BEAM
  abstract typespec forms returned by the standard library Code.Typespec fetch
  helpers.
  """

  alias RustQ.Meta.Type
  alias RustQ.Rust.Identifier

  @doc "Lowers a typespec type form to `RustQ.Meta.Type` metadata."
  @spec type(term(), map()) :: Type.t()
  def type(spec, aliases \\ %{}) do
    spec
    |> normalize()
    |> Type.parse(aliases)
  end

  @doc "Converts structured `RustQ.Syn.Type` metadata into `RustQ.Meta.Type` metadata."
  @spec from_syn(RustQ.Syn.type()) :: Type.t()
  def from_syn(type), do: Type.from_syn(type)

  @doc "Builds type aliases from quoted or BEAM abstract type declarations."
  @spec aliases([term()]) :: map()
  def aliases(types) do
    types
    |> Enum.map(&normalize_type_decl/1)
    |> Type.type_aliases()
  end

  @doc "Extracts aliases, function specs, and argument names from an Elixir source file."
  @spec declarations_file!(Path.t()) :: %{
          aliases: %{optional({atom(), non_neg_integer()}) => Type.t()},
          specs: [{atom(), [Macro.t()]}],
          defs: %{optional(atom()) => [atom()]}
        }
  def declarations_file!(path) when is_binary(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> declarations()
  end

  @doc "Extracts aliases, function specs, and argument names from quoted module AST."
  @spec declarations(Macro.t()) :: %{
          aliases: %{optional({atom(), non_neg_integer()}) => Type.t()},
          specs: [{atom(), [Macro.t()]}],
          defs: %{optional(atom()) => [atom()]}
        }
  def declarations({:defmodule, _meta, [_module, [do: body]]}), do: declarations(body)

  def declarations(quoted) do
    {types, specs, defs} =
      quoted
      |> block_expressions()
      |> Enum.reduce({[], [], %{}}, fn
        {:@, meta, [{:type, _, [{:"::", _, [_name_ast, _type_ast]} = type_ast]}]},
        {types, specs, defs} ->
          {[{:type, type_ast, line(meta)} | types], specs, defs}

        {:@, _, [{:spec, _, [{:"::", _, [{name, _, arg_types}, _return]}]}]},
        {types, specs, defs} ->
          {types, specs ++ [{name, arg_types}], defs}

        {:def, _, [{name, _, args}, _body]}, {types, specs, defs} ->
          {types, specs, Map.put(defs, name, Enum.map(args || [], &arg_name!/1))}

        _other, acc ->
          acc
      end)

    %{aliases: aliases(types), specs: specs, defs: defs}
  end

  @doc "Normalizes a quoted or BEAM abstract typespec form to quoted AST."
  @spec normalize(term()) :: Macro.t()
  def normalize({:type, _line, name, args}) when is_atom(name) do
    normalize_type(name, args)
  end

  def normalize({:remote_type, _line, [{:atom, _, module}, {:atom, _, function}, args]}) do
    {{:., [], [module_ast(module), function]}, [], Enum.map(args, &normalize/1)}
  end

  def normalize({:user_type, _line, name, args}) do
    {name, [], Enum.map(args, &normalize/1)}
  end

  def normalize({:atom, line, atom}) when is_integer(line), do: atom
  def normalize({:integer, line, integer}) when is_integer(line), do: integer

  def normalize({:ann_type, _line, [_var, type]}), do: normalize(type)
  def normalize({:paren_type, _line, [type]}), do: normalize(type)

  def normalize({:fun, _line, _} = ast), do: ast
  def normalize({:type, _line, :fun, _} = ast), do: ast

  def normalize(ast), do: ast

  defp normalize_type(:map, fields), do: {:%{}, [], Enum.map(fields, &normalize_map_field/1)}
  defp normalize_type(:tuple, elems), do: {:{}, [], Enum.map(elems, &normalize/1)}
  defp normalize_type(:union, elems), do: union_ast(Enum.map(elems, &normalize/1))
  defp normalize_type(nil, []), do: nil
  defp normalize_type(:binary, []), do: quote(do: binary())

  defp normalize_type(name, args) do
    {name, [], Enum.map(args, &normalize/1)}
  end

  defp normalize_map_field({:type, _line, :map_field_exact, [{:atom, _, key}, type]}) do
    {{:required, [], [key]}, normalize(type)}
  end

  defp normalize_map_field({:type, _line, :map_field_assoc, [{:atom, _, key}, type]}) do
    {{:optional, [], [key]}, normalize(type)}
  end

  defp union_ast([one]), do: one
  defp union_ast([left, right]), do: {:|, [], [left, right]}
  defp union_ast([left | rest]), do: {:|, [], [left, union_ast(rest)]}

  defp normalize_type_decl(
         {:type, {:"::", meta, [{name, name_meta, context}, type]} = _type_ast, line}
       )
       when is_atom(name) and is_atom(context) do
    {:type, {:"::", meta, [{name, name_meta, nil}, type]}, line}
  end

  defp normalize_type_decl({:type, {:"::", _, _} = type_ast, line}) do
    {:type, type_ast, line}
  end

  defp normalize_type_decl({kind, {name, type, args}}) when kind in [:type, :opaque] do
    {:type, {:"::", [], [{name, [], anonymous_args(args)}, normalize(type)]}, 0}
  end

  defp normalize_type_decl({:type, {name, type, args}, line}) do
    {:type, {:"::", [], [{name, [], anonymous_args(args)}, normalize(type)]}, line}
  end

  defp normalize_type_decl(type_decl), do: type_decl

  # A declaration's line, from parsed source or from `quote location: :keep`.
  defp line(meta) do
    case Keyword.fetch(meta, :keep) do
      {:ok, {_file, line}} -> meta[:line] || line
      :error -> meta[:line] || 0
    end
  end

  defp arg_name!({name, _meta, context}) when is_atom(name) and is_atom(context), do: name

  defp arg_name!(other),
    do:
      raise(ArgumentError, "unsupported function declaration argument #{Macro.to_string(other)}")

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp anonymous_args(args), do: Enum.map(args, fn _arg -> {:_, [], Elixir} end)

  defp module_ast(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&Identifier.atom!/1)
    |> then(&{:__aliases__, [], &1})
  end
end
