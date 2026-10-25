defmodule RustQ.Meta.Lower.Paths do
  @moduledoc """
  The Rust paths Elixir aliases name, and the callables a path or a receiver's type reaches.

  An alias a `defrustmod` maps is that Rust module, with what follows it; an alias ending in a
  plural, as `Atoms`, is a Rust module in snake case; any other is a Rust type or module as
  written. A call through a path or on a receiver finds its signature among the callables
  RustQ knows, trying the targets the path may name.
  """

  alias RustQ.Binding.Index, as: BindingIndex
  alias RustQ.Diagnostic
  alias RustQ.Meta.Lower.Env, as: Context
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Rust.Identifier

  @doc """
  The return type of a local or remote call, from the callable metadata the `:callables` option
  supplies, which tells lowering when a call returning `Result`, `Option`, or `NifResult`
  lowers with Rust `?`.
  """
  @spec callable_return_type(Macro.t(), keyword()) :: Type.t() | nil
  def callable_return_type(call_ast, opts \\ []) do
    callables = opts |> Keyword.get(:callables, []) |> BindingIndex.new()
    rust_modules = Keyword.get(opts, :rust_modules, %{})
    vars = Keyword.get(opts, :vars, %{})

    callable_return_type_from_index(call_ast, callables, rust_modules, vars)
  end

  @doc "Whether alias `parts` end in an upper-case segment, as a constant such as `Kind.PLAIN`."
  # A constant ends in an upper-case segment such as `Kind.PLAIN`.
  def constant_alias?(parts) do
    name = parts |> List.last() |> Atom.to_string()
    name == String.upcase(name) and String.length(name) > 1
  end

  @doc "The argument types of the callable `function/arity` on `target` (nil for a function), from the callables RustQ knows."
  def callable_argument_types(target, function, arity, %Context{callables: callables}) do
    callable_argument_types(callables, target, function, arity)
  end

  def callable_argument_types(%BindingIndex{} = callables, target, function, arity) do
    BindingIndex.argument_types(callables, target, function, arity)
  end

  @doc "The argument types of a function a Rust path names, trying each target the path may mean."
  def path_callable_argument_types(path, function, arity, %Context{} = context) do
    path_callable_argument_types(path, function, arity, context.callables, context.rust_modules)
  end

  def path_callable_argument_types(
        path,
        function,
        arity,
        %BindingIndex{} = callables,
        rust_modules
      ) do
    target_parts = Enum.drop(path, -1)

    parent_module_callable_argument_types(target_parts, function, arity, callables) ||
      target_parts
      |> exact_callable_target_candidates(rust_modules)
      |> Enum.find_value(&callable_argument_types(callables, &1, function, arity)) ||
      path_module_fallback_argument_types(target_parts, function, arity, callables) ||
      target_parts
      |> callable_target_candidates(rust_modules)
      |> Enum.find_value(&callable_argument_types(callables, &1, function, arity))
  end

  @doc "The argument types of a function `Super.function` names, in the module's parent."
  def parent_module_callable_argument_types(
        [:Super],
        function,
        arity,
        %BindingIndex{} = callables
      ),
      do:
        callable_argument_types(callables, nil, function, arity) ||
          BindingIndex.unqualified_argument_types(callables, function, arity)

  def parent_module_callable_argument_types(_target_parts, _function, _arity, %BindingIndex{}),
    do: nil

  defp path_module_fallback_argument_types(
         target_parts,
         function,
         arity,
         %BindingIndex{} = callables
       ) do
    if rust_module_path?(target_parts) do
      callable_argument_types(callables, nil, function, arity)
    end
  end

  defp parent_module_callable_return_type([:Super], function, arity, %BindingIndex{} = callables),
    do:
      BindingIndex.return_type(callables, nil, function, arity) ||
        BindingIndex.unqualified_return_type(callables, function, arity)

  defp parent_module_callable_return_type(_target_parts, _function, _arity, %BindingIndex{}),
    do: nil

  defp path_module_fallback_return_type(
         target_parts,
         function,
         arity,
         %BindingIndex{} = callables
       ) do
    if rust_module_path?(target_parts) do
      BindingIndex.return_type(callables, nil, function, arity)
    end
  end

  defp rust_module_path?([_ | _] = parts),
    do: rust_module_name?(parts |> List.last() |> to_string())

  defp rust_module_path?(_parts), do: false

  defp rust_module_name?(<<first, _rest::binary>>) when first in ?a..?z, do: true

  defp rust_module_name?(<<"_", _rest::binary>>), do: true

  defp rust_module_name?(_name), do: false

  @doc "The callable target, as a Rust type name, a receiver of `type` calls methods on."
  def callable_target_from_type(%Type{} = type), do: Type.callable_target(type)

  def callable_target_from_type(_type), do: nil

  @doc "The type a callable target names."
  def type_for_callable_target(target) when is_binary(target) do
    ast =
      case callable_target_parts(target) do
        [_ | _] = parts -> %AST.TypePath{parts: parts}
        nil -> %AST.TypeRaw{source: target}
      end

    %Type{kind: :type, rust: target, ast: ast}
  end

  defp callable_target_parts(target) do
    parts = String.split(target, "::")

    if Enum.all?(parts, &simple_rust_identifier?/1) do
      Enum.map(parts, &Identifier.atom!/1)
    end
  end

  @doc "Whether `ast` is an alias."
  def alias_ast?({:__aliases__, _, _parts}), do: true

  def alias_ast?(_other), do: false

  @doc "Whether `ast` is an alias or a field path through one, as `Kinds.FANCY`."
  def alias_path_ast?({:__aliases__, _, _parts}), do: true

  def alias_path_ast?({{:., _, [receiver, _field]}, meta, []}),
    do: Keyword.get(meta, :no_parens, false) and alias_path_ast?(receiver)

  def alias_path_ast?(_other), do: false

  @doc "Whether `ast` is `Super`, the Rust parent module."
  def super_alias_ast?({:__aliases__, _, [:Super]}), do: true

  def super_alias_ast?(_other), do: false

  @doc "Whether `ast` is an alias RustQ reserves for building Rust AST, as `Stmt`."
  def rust_constructor_alias?({:__aliases__, _, [module]}) when module in [:Stmt], do: true

  def rust_constructor_alias?(_other), do: false

  @doc "The Rust path an alias names; see the module docs."
  def alias_parts({:__aliases__, _, parts}, rust_modules),
    do: mapped_alias_parts(parts, rust_modules)

  @doc "The Rust path an alias or field path through one names."
  def alias_path_parts(ast, rust_modules),
    do: ast |> raw_alias_path_parts() |> mapped_alias_parts(rust_modules)

  defp raw_alias_path_parts(ast), do: raw_alias_path_parts(ast, [])

  defp raw_alias_path_parts({:__aliases__, _, parts}, acc) do
    parts
    |> Enum.reverse()
    |> Enum.reduce(acc, &[&1 | &2])
  end

  defp raw_alias_path_parts({{:., _, [receiver, field]}, meta, []} = ast, acc) do
    if Keyword.get(meta, :no_parens, false) do
      raw_alias_path_parts(receiver, [field | acc])
    else
      Diagnostic.lower(:unsupported_alias_path, ast, "unsupported alias path")
    end
  end

  @doc "The Rust path alias `parts` name, through the longest `defrustmod` mapping of a prefix."
  def mapped_alias_parts(parts, rust_modules) do
    parts
    |> alias_prefixes()
    |> Enum.find_value(fn {prefix, suffix} ->
      mapped = Map.get(rust_modules, prefix)
      if mapped, do: mapped ++ suffix
    end) || automatic_rust_alias_parts(parts)
  end

  @doc "The ways to split alias `parts` into a prefix and the rest, longest prefix first."
  def alias_prefixes(parts) do
    parts
    |> length()
    |> Range.new(1, -1)
    |> Enum.map(fn count -> Enum.split(parts, count) end)
  end

  defp automatic_rust_alias_parts(parts) do
    if rust_module_alias?(parts) do
      Enum.map(parts, &rust_module_part/1)
    else
      parts
    end
  end

  defp rust_module_alias?(parts) do
    parts
    |> List.last()
    |> Atom.to_string()
    |> String.ends_with?("s")
  end

  defp rust_module_part(part),
    do: Identifier.atom!(Macro.underscore(Atom.to_string(part)))

  defp callable_return_type_from_index(
         {name, _meta, args},
         %BindingIndex{} = callables,
         _rust_modules,
         _vars
       )
       when is_atom(name) and is_list(args) do
    BindingIndex.return_type(callables, nil, name, length(args))
  end

  defp callable_return_type_from_index(
         {{:., _, [{:__aliases__, _, parts}, function]}, _meta, args},
         %BindingIndex{} = callables,
         rust_modules,
         _vars
       )
       when is_atom(function) and is_list(args) do
    arity = length(args)

    callable_return_type_for_path(parts, function, arity, callables, rust_modules)
  end

  defp callable_return_type_from_index(
         {{:., _, [receiver, function]}, _meta, args},
         %BindingIndex{} = callables,
         _rust_modules,
         vars
       )
       when is_atom(function) and is_list(args) do
    target =
      receiver
      |> variable_type(vars)
      |> callable_target_from_type()

    BindingIndex.return_type(callables, target, function, length(args))
  end

  defp callable_return_type_from_index(_call_ast, %BindingIndex{}, _rust_modules, _vars), do: nil

  defp callable_return_type_for_path(
         parts,
         function,
         arity,
         callables,
         rust_modules
       ) do
    parent_module_callable_return_type(parts, function, arity, callables) ||
      parts
      |> callable_target_candidates(rust_modules)
      |> Enum.find_value(&BindingIndex.return_type(callables, &1, function, arity)) ||
      path_module_fallback_return_type(parts, function, arity, callables)
  end

  defp exact_callable_target_candidates(parts, rust_modules) do
    mapped = mapped_alias_parts(parts, rust_modules)

    [
      Enum.map_join(mapped, "::", &to_string/1),
      mapped |> List.last() |> to_string(),
      Enum.map_join(parts, "::", &to_string/1),
      parts |> List.last() |> to_string()
    ]
    |> Enum.uniq()
  end

  defp callable_target_candidates(parts, rust_modules) do
    mapped = mapped_alias_parts(parts, rust_modules)
    mapped_last = List.last(mapped)
    parts_last = List.last(parts)

    [
      Enum.map_join(mapped, "::", &to_string/1),
      to_string(mapped_last),
      singular_candidate(mapped_last),
      singular_module_candidate(mapped_last),
      Enum.map_join(parts, "::", &to_string/1),
      to_string(parts_last),
      singular_candidate(parts_last),
      singular_module_candidate(parts_last)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp singular_candidate(part) when is_atom(part),
    do: part |> to_string() |> singular_candidate()

  defp singular_candidate(part) when is_binary(part) do
    if String.ends_with?(part, "s") and String.length(part) > 1 do
      String.trim_trailing(part, "s")
    end
  end

  defp singular_candidate(_part), do: nil

  defp singular_module_candidate(part) do
    case singular_candidate(part) do
      nil -> nil
      singular -> Macro.camelize(singular)
    end
  end

  defp variable_type({name, _, context}, vars) when is_atom(name) and is_atom(context),
    do: Map.get(vars, name)

  defp variable_type(_expression, _vars), do: nil

  defp simple_rust_identifier?(<<first, rest::binary>>) when first in ?A..?Z or first in ?a..?z,
    do: simple_rust_identifier_tail?(rest)

  defp simple_rust_identifier?(<<"_", rest::binary>>), do: simple_rust_identifier_tail?(rest)
  defp simple_rust_identifier?(""), do: false

  defp simple_rust_identifier_tail?(<<>>), do: true

  defp simple_rust_identifier_tail?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9,
       do: simple_rust_identifier_tail?(rest)

  defp simple_rust_identifier_tail?(<<"_", rest::binary>>), do: simple_rust_identifier_tail?(rest)
  defp simple_rust_identifier_tail?(_invalid), do: false
end
