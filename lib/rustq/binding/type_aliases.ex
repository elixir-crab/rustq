defmodule RustQ.Binding.TypeAliases do
  @moduledoc "Source-backed Rust type alias expansion for native receiver inference."
  alias RustQ.Binding.Substitution
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Walk
  alias RustQ.Rust.Identifier
  alias RustQ.SourceFingerprint
  alias RustQ.Syn

  def from_files([]), do: %{}

  def from_files(paths) do
    fingerprint = Enum.map(paths, &SourceFingerprint.file/1)
    key = {__MODULE__, paths}

    case :persistent_term.get(key, nil) do
      {^fingerprint, aliases} ->
        aliases

      _ ->
        aliases = read_files(paths)
        :persistent_term.put(key, {fingerprint, aliases})
        aliases
    end
  end

  defp read_files(paths) do
    paths
    |> Enum.flat_map(fn path ->
      file = Syn.parse_file!(path)

      imports = imports!(file)

      Enum.map(Syn.type_aliases(file), fn alias_type ->
        definition(alias_type, imports)
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, definitions} ->
      case Enum.uniq(definitions) do
        [definition] -> {name, definition}
        _ -> {name, {:unsupported, :ambiguous}}
      end
    end)
  end

  defp definition(%{module_path: [_ | _], name: name}, _imports),
    do: {name, {:unsupported, :nested}}

  defp definition(alias_type, imports) do
    ast = alias_type.type_ast |> Type.from_syn() |> Map.fetch!(:ast)
    ast = qualify(ast, Map.drop(imports, alias_type.type_parameters))
    {alias_type.name, {alias_type.type_parameters, ast}}
  end

  defp imports!(file) do
    file
    |> Syn.uses()
    |> Enum.filter(&(&1.module_path == []))
    |> Map.new(fn use -> {use.alias || List.last(use.segments), use.segments} end)
  end

  def expand(%Type{} = type, aliases) do
    ast = expand_ast(type.ast, aliases, [])

    if ast == type.ast do
      %{type | meta: expand_metadata(type.meta, aliases)}
    else
      expanded = Type.ast_type(ast)

      if type.ast.__struct__ == ast.__struct__ and not alias_root?(type.ast, aliases) do
        %{type | ast: ast, rust: expanded.rust, meta: expand_metadata(type.meta, aliases)}
      else
        expanded
      end
    end
  end

  defp alias_root?(%AST.TypePath{parts: [name]}, aliases),
    do: Map.has_key?(aliases, to_string(name))

  defp alias_root?(_ast, _aliases), do: false

  defp expand_metadata(%Type{} = type, aliases), do: expand(type, aliases)
  defp expand_metadata(%module{} = value, _aliases) when module != Type, do: value

  defp expand_metadata(value, aliases) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, expand_metadata(item, aliases)} end)

  defp expand_metadata(value, aliases) when is_list(value),
    do: Enum.map(value, &expand_metadata(&1, aliases))

  defp expand_metadata(value, aliases) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&expand_metadata(&1, aliases)) |> List.to_tuple()

  defp expand_metadata(value, _aliases), do: value

  defp expand_ast(%AST.TypePath{parts: [name], generics: args} = ast, aliases, seen) do
    case Map.get(aliases, to_string(name)) do
      {:unsupported, reason} ->
        raise ArgumentError, "#{reason} Rust type alias #{name} requires scoped resolution"

      {parameters, body} when length(parameters) == length(args) ->
        reject_lifetime_alias!(ast, body)
        if name in seen, do: raise(ArgumentError, "cyclic Rust type alias #{name}")
        bindings = Map.new(Enum.zip(parameters, args))
        body = Substitution.apply(Type.ast_type(body), bindings).ast
        expand_ast(body, aliases, [name | seen])

      _ ->
        %{ast | generics: Enum.map(args, &expand_ast(&1, aliases, seen))}
    end
  end

  defp expand_ast(%AST.TypePath{} = ast, aliases, seen),
    do: %{ast | generics: Enum.map(ast.generics, &expand_ast(&1, aliases, seen))}

  defp expand_ast(%AST.TypeRef{} = ast, aliases, seen),
    do: %{ast | inner: expand_ast(ast.inner, aliases, seen)}

  defp expand_ast(%AST.TypeOption{} = ast, aliases, seen),
    do: %{ast | inner: expand_ast(ast.inner, aliases, seen)}

  defp expand_ast(%AST.TypeVec{} = ast, aliases, seen),
    do: %{ast | inner: expand_ast(ast.inner, aliases, seen)}

  defp expand_ast(%AST.TypeResult{} = ast, aliases, seen),
    do: %{
      ast
      | ok: expand_ast(ast.ok, aliases, seen),
        error: expand_ast(ast.error, aliases, seen)
    }

  defp expand_ast(ast, _aliases, _seen), do: ast

  defp reject_lifetime_alias!(use, body) do
    has_lifetime =
      Walk.reduce([use, body], false, fn
        %AST.TypeRef{lifetime: lifetime}, found -> found or not is_nil(lifetime)
        %AST.TypePath{lifetimes: lifetimes}, found -> found or lifetimes != []
        _, found -> found
      end)

    if has_lifetime, do: raise(ArgumentError, "lifetime alias substitution is not supported")
  end

  defp qualify(%AST.TypePath{parts: [name]} = ast, imports) do
    parts =
      Map.get(imports, to_string(name), ast.parts) |> Enum.map(&Identifier.atom!/1)

    %{ast | parts: parts, generics: Enum.map(ast.generics, &qualify(&1, imports))}
  end

  defp qualify(%AST.TypeRef{} = ast, imports), do: %{ast | inner: qualify(ast.inner, imports)}
  defp qualify(ast, _imports), do: ast
end
