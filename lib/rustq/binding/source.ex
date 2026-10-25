defmodule RustQ.Binding.Source do
  @moduledoc """
  Resolves callable metadata from RustQ modules, Rust source files, and Cargo packages.

  This module is the source-backed callable metadata boundary used by
  `RustQ.Meta`. It keeps parsing, package indexing, alias-equivalence annotation,
  caching, and configuration diagnostics out of the macro frontend.
  """

  alias RustQ.Binding.Callable
  alias RustQ.Diagnostic
  alias RustQ.Meta.Type
  alias RustQ.Rust.Identifier
  alias RustQ.SourceFingerprint
  alias RustQ.Spec
  alias RustQ.Syn

  @type rust_package :: String.t() | {String.t(), keyword()}

  @doc "Resolves external callable metadata configured on a `use RustQ.Meta` module."
  @spec external_callables(module()) :: [Callable.t()]
  def external_callables(module) when is_atom(module) do
    rust_source_callables_for_module(module) ++
      rust_package_callables_for_module(module) ++
      callable_module_callables(module)
  end

  @doc """
  The type aliases declared by a module's callable modules, so its specs and types may name
  them as their own.
  """
  @spec external_type_aliases(module()) :: %{module() => map()}
  def external_type_aliases(module) when is_atom(module) do
    module
    |> Module.get_attribute(:rustq_callable_modules)
    |> List.wrap()
    |> List.flatten()
    |> Enum.uniq()
    |> Map.new(fn callable_module ->
      callable_module_callables!(callable_module)

      if function_exported?(callable_module, :__rustq_types__, 0),
        do: {callable_module, callable_module.__rustq_types__()},
        else: {callable_module, %{}}
    end)
  end

  @doc """
  Callables read from a module's `:provides` files, which join its own in
  `__rustq_callables__/0`.
  """
  @spec provided_callables(module()) :: [Callable.t()]
  def provided_callables(module) when is_atom(module) do
    module
    |> provided_paths()
    |> cached_rust_source_callables()
  end

  @doc """
  Rust types declared in a module's `:provides` files, as the Elixir types other modules name
  them by: `KiwiRecord` is `kiwi_record()`. Types with lifetimes or type parameters are left
  out.
  """
  @spec provided_types(module()) :: %{optional({atom(), 0}) => Type.t()}
  def provided_types(module) when is_atom(module) do
    case provided_paths(module) do
      [] ->
        %{}

      paths ->
        index = rust_source_index!(paths)

        (Syn.Index.structs(index) ++ Syn.Index.enums(index))
        |> Enum.filter(
          &(&1.visibility == :public and &1.lifetimes == [] and &1.type_parameters == [])
        )
        |> Map.new(&{{provided_type_name(&1.name), 0}, provided_type(&1.name)})
    end
  end

  @doc "Rust source of a module's `:provides` files, as the module emits it."
  @spec provided_source(module()) :: String.t()
  def provided_source(module) when is_atom(module) do
    module
    |> provided_paths()
    |> Enum.map_join("\n\n", &(&1 |> File.read!() |> String.trim_trailing()))
  end

  @doc """
  The module an alias in a RustQ module names, when it was written through `alias`: found among
  `env`'s aliases, or recorded on the alias by `quote` in the macro that wrote it. Other aliases
  are Rust paths.
  """
  @spec aliased_module(Macro.t(), Macro.Env.t()) :: module() | nil
  def aliased_module({:__aliases__, meta, [head | _]} = alias_ast, env) when is_atom(head) do
    case Keyword.get(meta, :alias) do
      module when is_atom(module) and module not in [nil, false] ->
        module

      _unrecorded ->
        if List.keymember?(env.aliases, Module.concat([head]), 0),
          do: Macro.expand(alias_ast, env)
    end
  end

  def aliased_module(_ast, _env), do: nil

  @doc """
  The RustQ modules `asts` name through `alias`, which a module imports as it does its
  `:callable_modules`, the way Elixir resolves a module by its name.
  """
  @spec aliased_callable_modules([Macro.t()], Macro.Env.t()) :: [module()]
  def aliased_callable_modules(asts, %Macro.Env{} = env) do
    asts
    |> Enum.flat_map(&aliased_modules(&1, env))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == env.module))
    |> Enum.filter(&rustq_module?/1)
  end

  # `Runtime.Entry` reaches into `Runtime` when `Runtime` is a RustQ module, as for the Rust
  # modules it maps, without waiting on a nested module the compiler may never define.
  defp aliased_modules(ast, env) do
    ast
    |> Macro.prewalk([], fn
      {:__aliases__, meta, [head | _]} = node, modules ->
        head_module = aliased_module({:__aliases__, meta, [head]}, env)

        module =
          if head_module && rustq_module?(head_module),
            do: head_module,
            else: aliased_module(node, env)

        {node, if(module, do: [module | modules], else: modules)}

      node, modules ->
        {node, modules}
    end)
    |> elem(1)
  end

  defp rustq_module?(module) do
    match?({:module, ^module}, Code.ensure_compiled(module)) and
      function_exported?(module, :__rustq_callables__, 0)
  end

  @doc "Resolves external static item types configured on a `use RustQ.Meta` module."
  @spec external_static_types(module()) :: %{optional(atom()) => Type.t()}
  def external_static_types(module) when is_atom(module) do
    module
    |> rust_source_paths_for_module()
    |> cached_rust_source_static_types()
  end

  @doc "Expands Rust source paths relative to the current project working directory."
  @spec rust_source_paths([Path.t()] | Path.t() | nil) :: [Path.t()]
  def rust_source_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.map(&rust_source_path/1)
  end

  defp rust_source_path(path) when is_binary(path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, File.cwd!())
  end

  defp provided_paths(module) do
    module
    |> Module.get_attribute(:rustq_provides)
    |> List.wrap()
    |> List.flatten()
    |> Enum.uniq()
  end

  defp provided_type_name(rust_name), do: rust_name |> Macro.underscore() |> Identifier.atom!()

  defp provided_type(rust_name),
    do: Spec.type({{:., [], [{:__aliases__, [], [Identifier.atom!(rust_name)]}, :t]}, [], []})

  defp rust_source_callables_for_module(module) do
    module
    |> rust_source_paths_for_module()
    |> cached_rust_source_callables()
  end

  defp rust_source_paths_for_module(module) do
    module
    |> Module.get_attribute(:rustq_rust_sources)
    |> List.wrap()
    |> List.flatten()
    |> Enum.uniq()
  end

  defp callable_module_callables(module) do
    module
    |> Module.get_attribute(:rustq_callable_modules)
    |> List.wrap()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&cached_callable_module_callables/1)
  end

  defp cached_callable_module_callables(module), do: callable_module_callables!(module)

  defp callable_module_callables!(module) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        unless function_exported?(module, :__rustq_callables__, 0) do
          Diagnostic.defrust(
            :invalid_callable_module,
            module,
            "configured RustQ callable module does not expose __rustq_callables__/0",
            details: %{module: module}
          )
        end

        module.__rustq_callables__()

      {:error, reason} ->
        Diagnostic.defrust(
          :callable_module_compile_failed,
          module,
          "configured RustQ callable module could not be compiled",
          details: %{module: module, reason: reason}
        )
    end
  end

  defp cached_rust_source_static_types([]), do: %{}

  defp cached_rust_source_static_types(paths) do
    fingerprint = rust_sources_fingerprint(paths)
    cache_key = {__MODULE__, :static_types, {:rust_sources, paths}}

    case :persistent_term.get(cache_key, :missing) do
      {:rust_sources, ^fingerprint, static_types} ->
        static_types

      _missing_or_stale ->
        static_types = rust_source_static_types(paths)
        :persistent_term.put(cache_key, {:rust_sources, fingerprint, static_types})
        static_types
    end
  end

  defp cached_rust_source_callables([]), do: []

  defp cached_rust_source_callables(paths) do
    fingerprint = rust_sources_fingerprint(paths)
    cache_key = {__MODULE__, :callables, {:rust_sources, paths}}

    case :persistent_term.get(cache_key, :missing) do
      {:rust_sources, ^fingerprint, callables} ->
        callables

      _missing_or_stale ->
        callables = rust_source_callables(paths)
        :persistent_term.put(cache_key, {:rust_sources, fingerprint, callables})
        callables
    end
  end

  defp rust_source_static_types(paths) do
    index = rust_source_index!(paths)
    conversions = from_conversions(index)

    index
    |> Syn.Index.statics()
    |> Map.new(fn static ->
      {Identifier.atom!(static.name),
       annotate_type(Spec.from_syn(static.type_ast), index, conversions)}
    end)
  end

  defp rust_sources_fingerprint(paths) do
    Enum.map(paths, &rust_source_fingerprint/1)
  end

  defp rust_source_fingerprint(path), do: SourceFingerprint.file(path)

  defp rust_source_callables(paths) do
    index = rust_source_index!(paths)
    index_callables(index, from_conversions(index))
  end

  defp rust_source_index!(paths) do
    Enum.each(paths, &validate_rust_source!/1)

    try do
      Syn.Index.from_paths(paths)
    rescue
      error in [RustQ.Error, File.Error, ArgumentError, RuntimeError] ->
        Diagnostic.defrust(
          :rust_source_parse_failed,
          paths,
          "configured Rust sources could not be parsed",
          details: %{paths: paths, error: error}
        )
    end
  end

  defp validate_rust_source!(path) do
    unless File.regular?(path) do
      Diagnostic.defrust(:invalid_rust_source, path, "configured Rust source does not exist",
        details: %{path: path}
      )
    end
  end

  defp rust_package_callables_for_module(module) do
    module
    |> Module.get_attribute(:rustq_rust_packages)
    |> List.wrap()
    |> List.flatten()
    |> Enum.flat_map(&cached_rust_package_callables/1)
  end

  # The package index owns freshness and caching. An outer permanent cache
  # would prevent its invalidation checks from running after a source change.
  defp cached_rust_package_callables(config), do: rust_package_callables(config)

  defp rust_package_callables(package) when is_binary(package),
    do: rust_package_callables({package, []})

  defp rust_package_callables({package, opts}) when is_binary(package) and is_list(opts) do
    index =
      try do
        Syn.Index.cached_package(package, opts)
      rescue
        error in [RustQ.Error, Mix.Error, ArgumentError, RuntimeError] ->
          Diagnostic.defrust(
            :rust_package_load_failed,
            package,
            "configured Rust package could not be loaded",
            details: %{package: package, opts: opts, error: error}
          )
      end

    conversions = from_conversions(index)

    index_callables(index, conversions)
  end

  defp index_callables(index, conversions) do
    function_callables =
      index.files
      |> Map.values()
      |> Enum.flat_map(&Syn.functions/1)
      |> Enum.map(&Callable.from_syn_function/1)
      |> Enum.map(&annotate_callable_types(&1, index, conversions))

    method_callables =
      index
      |> Syn.Index.impls()
      |> Enum.flat_map(&impl_callables/1)
      |> Enum.map(&annotate_callable_types(&1, index, conversions))

    function_callables ++ method_callables
  end

  defp impl_callables(%Syn.Impl{} = impl) do
    self_type = Spec.from_syn(impl.target_ast)

    Enum.map(impl.methods, fn method ->
      method
      |> Callable.from_syn_method(
        target: impl.target,
        target_type: RustQ.Spec.from_syn(impl.target_ast)
      )
      |> resolve_self_types(self_type)
    end)
  end

  defp resolve_self_types(%Callable{} = callable, %Type{} = self_type) do
    %{
      callable
      | args: Enum.map(callable.args, &resolve_self_arg(&1, self_type)),
        returns: resolve_self_type(callable.returns, self_type)
    }
  end

  defp resolve_self_arg(%{type: %Type{} = type} = arg, %Type{} = self_type),
    do: %{arg | type: resolve_self_type(type, self_type)}

  defp resolve_self_arg(arg, _self_type), do: arg

  defp resolve_self_type(%Type{rust: "Self"}, %Type{} = self_type), do: self_type

  defp resolve_self_type(
         %Type{kind: kind, meta: %{inner: %Type{} = inner} = meta} = type,
         self_type
       )
       when kind in [:option, :ref, :mut_ref, :vec] do
    %{type | meta: Map.put(meta, :inner, resolve_self_type(inner, self_type))}
  end

  defp resolve_self_type(
         %Type{kind: :tuple, meta: %{elements: elements} = meta} = type,
         self_type
       ) do
    %{
      type
      | meta: Map.put(meta, :elements, Enum.map(elements, &resolve_self_type(&1, self_type)))
    }
  end

  defp resolve_self_type(%Type{kind: :result} = type, self_type) do
    meta =
      type.meta
      |> resolve_self_meta_type(:ok, self_type)
      |> resolve_self_meta_type(:error, self_type)

    %{type | meta: meta}
  end

  defp resolve_self_type(
         %Type{kind: :impl_trait, meta: %{traits: traits} = meta} = type,
         self_type
       ) do
    %{type | meta: Map.put(meta, :traits, Enum.map(traits, &resolve_self_type(&1, self_type)))}
  end

  defp resolve_self_type(%Type{meta: %{args: args} = meta} = type, self_type)
       when is_list(args) do
    %{type | meta: Map.put(meta, :args, Enum.map(args, &resolve_self_type(&1, self_type)))}
  end

  defp resolve_self_type(type, _self_type), do: type

  defp resolve_self_meta_type(meta, key, self_type) do
    case Map.fetch(meta, key) do
      {:ok, %Type{} = type} -> Map.put(meta, key, resolve_self_type(type, self_type))
      _missing_or_other -> meta
    end
  end

  defp annotate_callable_types(%Callable{} = callable, %Syn.Index{} = index, conversions) do
    %{
      callable
      | args: Enum.map(callable.args, &annotate_callable_arg(&1, index, conversions)),
        returns: annotate_type(callable.returns, index, conversions)
    }
  end

  defp annotate_callable_arg(%{type: type} = arg, index, conversions),
    do: %{arg | type: annotate_type(type, index, conversions)}

  defp annotate_type(%Type{} = type, index, conversions) do
    type
    |> annotate_public_alias_type(index)
    |> annotate_from_conversion_type(conversions)
    |> annotate_nested_type(index, conversions)
  end

  defp annotate_type(nil, _index, _conversions), do: nil

  defp annotate_public_alias_type(%Type{kind: :type, meta: %{syn_name: name}} = type, index)
       when is_binary(name) do
    case Syn.Index.public_type_name(index, name) do
      {:ok, public_name} when public_name != name ->
        put_equivalent_rust_name(type, public_name)

      _missing_or_same ->
        type
    end
  end

  defp annotate_public_alias_type(%Type{} = type, _index), do: type

  defp put_equivalent_rust_name(%Type{} = type, name) do
    equivalents =
      type.meta
      |> Map.get(:equivalent_rust_names, [])
      |> List.wrap()
      |> Kernel.++([name])
      |> Enum.uniq()

    %{type | meta: Map.put(type.meta, :equivalent_rust_names, equivalents)}
  end

  defp from_conversions(%Syn.Index{} = index) do
    index
    |> Syn.Index.impls()
    |> Enum.reduce(%{}, fn impl, conversions ->
      case from_conversion(impl) do
        {%Type{} = from, %Type{} = to} ->
          Map.update(conversions, type_key(to), type_names(from), &(type_names(from) ++ &1))

        nil ->
          conversions
      end
    end)
    |> Map.new(fn {key, names} -> {key, Enum.uniq(names)} end)
  end

  defp from_conversion(%Syn.Impl{trait: trait, target_ast: target_ast, methods: methods})
       when is_binary(trait) do
    if from_trait?(trait), do: from_conversion(target_ast, methods)
  end

  defp from_conversion(%Syn.Impl{}), do: nil

  defp from_conversion(target_ast, methods) do
    with %Syn.Method{name: "from", args: [arg | _]} <- Enum.find(methods, &(&1.name == "from")),
         %Type{} = from <- Spec.from_syn(arg.type_ast),
         %Type{} = to <- Spec.from_syn(target_ast) do
      {from, to}
    else
      _not_from_impl -> nil
    end
  end

  defp from_trait?("From"), do: true

  defp from_trait?("From" <> rest) do
    rest
    |> String.trim_leading()
    |> String.starts_with?("<")
  end

  defp from_trait?(_trait), do: false

  defp annotate_from_conversion_type(%Type{} = type, conversions) do
    conversions
    |> Map.get(type_key(type), [])
    |> Enum.reduce(type, &put_equivalent_rust_name(&2, &1))
  end

  defp annotate_nested_type(%Type{kind: kind, meta: meta} = type, index, conversions)
       when kind in [:option, :ref, :mut_ref, :vec] do
    case meta do
      %{inner: %Type{} = inner} ->
        %{type | meta: Map.put(meta, :inner, annotate_type(inner, index, conversions))}

      _other ->
        type
    end
  end

  defp annotate_nested_type(%Type{kind: kind, meta: meta} = type, index, conversions)
       when kind in [:result] do
    meta =
      meta
      |> annotate_meta_type(:ok, index, conversions)
      |> annotate_meta_type(:error, index, conversions)

    %{type | meta: meta}
  end

  defp annotate_nested_type(
         %Type{kind: :tuple, meta: %{elements: elements} = meta} = type,
         index,
         conversions
       ) do
    elements = Enum.map(elements, &annotate_type(&1, index, conversions))
    %{type | meta: Map.put(meta, :elements, elements)}
  end

  defp annotate_nested_type(
         %Type{kind: :impl_trait, meta: %{traits: traits} = meta} = type,
         index,
         conversions
       ) do
    traits = Enum.map(traits, &annotate_type(&1, index, conversions))
    %{type | meta: Map.put(meta, :traits, traits)}
  end

  defp annotate_nested_type(%Type{meta: %{args: args} = meta} = type, index, conversions)
       when is_list(args) do
    args = Enum.map(args, &annotate_type(&1, index, conversions))
    %{type | meta: Map.put(meta, :args, args)}
  end

  defp annotate_nested_type(%Type{} = type, _index, _conversions), do: type

  defp annotate_meta_type(meta, key, index, conversions) do
    case Map.fetch(meta, key) do
      {:ok, %Type{} = type} -> Map.put(meta, key, annotate_type(type, index, conversions))
      _missing_or_other -> meta
    end
  end

  defp type_key(%Type{} = type) do
    type
    |> type_names()
    |> List.first()
  end

  defp type_names(%Type{} = type) do
    [type.rust, type.meta[:syn_name], type_name_from_ast(type.ast)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp type_name_from_ast(%RustQ.Rust.AST.TypePath{parts: [_ | _] = parts}),
    do: parts |> List.last() |> to_string()

  defp type_name_from_ast(_ast), do: nil
end
