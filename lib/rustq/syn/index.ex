defmodule RustQ.Syn.Index do
  @moduledoc """
  In-memory index of Rust source metadata parsed by `RustQ.Syn`.

  Use an index when a generator needs to query many Rust files without keeping
  project-specific source maps. The index stores parsed files by path and offers
  lookup helpers for impl blocks and methods by target type.

  It also indexes Rust `use` items and `type` aliases. Generators can inspect
  them directly with `uses/1` and `type_aliases/1`, or ask for the public Rust
  name that exposes a native/bindings type with `public_type_name/2` and
  `public_type_name!/2`. Reexport chains such as `pub use paint::Cap as
  PaintCap;` are followed so callers can prefer the crate's public API surface
  over internal module names.
  """

  alias RustQ.SourceFingerprint
  alias RustQ.Syn.Type
  alias RustQ.Syn.TypeAlias
  alias RustQ.Syn.Use

  defstruct files: %{}, package: nil

  @type t :: %__MODULE__{
          files: %{Path.t() => RustQ.Syn.File.t()},
          package: RustQ.Cargo.Package.t() | nil
        }

  @doc "Builds an index from Rust source file paths."
  @spec from_paths([Path.t()], keyword()) :: t()
  def from_paths(paths, opts \\ []) when is_list(paths) do
    files =
      paths
      |> Enum.uniq()
      |> Map.new(fn path ->
        {path, path |> RustQ.Syn.parse_file!() |> attach_source_path(path)}
      end)

    %__MODULE__{files: files, package: Keyword.get(opts, :package)}
  end

  @doc "Builds an index for all Rust sources in a Cargo package."
  @spec from_package(String.t(), keyword()) :: t()
  def from_package(package_name, opts \\ []) when is_binary(package_name) do
    package = RustQ.Cargo.package!(package_name, opts)

    package
    |> package_source_paths()
    |> from_paths(package: package)
  end

  @doc """
  Returns a cached index for all Rust sources in a Cargo package.

  The first caller builds a structural package index from Cargo metadata and the
  package's Rust source files. Concurrent callers for the same package/config are
  serialized so parallel compilation does not stampede Cargo metadata or package
  cache access; later callers read the already-built index from `:persistent_term`.

  Cached entries are fingerprinted from the Cargo manifest/lockfile inputs and
  indexed Rust source contents. Same-size edits with unchanged timestamps also
  invalidate the index; the next caller rebuilds it.
  """
  @spec cached_package(String.t(), keyword()) :: t()
  def cached_package(package_name, opts \\ []) when is_binary(package_name) do
    key = {__MODULE__, :package, package_name, Enum.sort(opts)}

    key
    |> :persistent_term.get(nil)
    |> cached_package_entry(key, package_name, opts)
  end

  defp cached_package_entry(nil, key, package_name, opts) do
    single_flight_package(key, fn -> fill_cached_package(key, package_name, opts) end)
  end

  defp cached_package_entry(
         {:package_index, fingerprint, %__MODULE__{} = index},
         key,
         package_name,
         opts
       ) do
    if fingerprint == package_fingerprint(index, opts) do
      index
    else
      single_flight_package(key, fn -> fill_cached_package(key, package_name, opts) end)
    end
  end

  defp cached_package_entry(%__MODULE__{} = index, key, _package_name, opts) do
    single_flight_package(key, fn -> refresh_legacy_cached_package(key, index, opts) end)
  end

  defp fill_cached_package(key, package_name, opts) do
    key
    |> :persistent_term.get(nil)
    |> fill_cached_package_entry(key, package_name, opts)
  end

  defp fill_cached_package_entry(nil, key, package_name, opts) do
    cache_package_index(key, from_package(package_name, opts), opts)
  end

  defp fill_cached_package_entry(
         {:package_index, fingerprint, %__MODULE__{} = index},
         key,
         package_name,
         opts
       ) do
    if fingerprint == package_fingerprint(index, opts) do
      index
    else
      cache_package_index(key, from_package(package_name, opts), opts)
    end
  end

  defp fill_cached_package_entry(%__MODULE__{} = index, key, _package_name, opts) do
    refresh_legacy_cached_package(key, index, opts)
  end

  defp refresh_legacy_cached_package(key, %__MODULE__{} = index, opts) do
    cache_package_index(key, index, opts)
  end

  defp cache_package_index(key, %__MODULE__{} = index, opts) do
    :persistent_term.put(key, {:package_index, package_fingerprint(index, opts), index})
    index
  end

  defp single_flight_package(key, fun) do
    :global.trans({{__MODULE__, :package_cache_fill, key}, self()}, fun, [node()], :infinity)
  end

  defp package_fingerprint(%__MODULE__{} = index, opts) do
    index
    |> package_fingerprint_paths(opts)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&file_fingerprint/1)
  end

  defp package_fingerprint_paths(%__MODULE__{files: files, package: package}, opts) do
    Map.keys(files) ++
      package_source_paths(package) ++
      package_manifest_paths(package) ++ project_manifest_paths(opts)
  end

  defp package_source_paths(%RustQ.Cargo.Package{manifest_path: manifest_path}) do
    manifest_path
    |> Path.dirname()
    |> Path.join("**/*.rs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp package_source_paths(nil), do: []

  defp package_manifest_paths(%RustQ.Cargo.Package{manifest_path: manifest_path}) do
    [manifest_path]
  end

  defp package_manifest_paths(nil), do: []

  defp project_manifest_paths(opts) do
    manifest_path = Keyword.get(opts, :manifest_path, "Cargo.toml")
    lock_path = manifest_path |> Path.dirname() |> Path.join("Cargo.lock")
    [manifest_path, lock_path]
  end

  defp file_fingerprint(path), do: SourceFingerprint.file(path)

  @doc "Clears a cached package index."
  @spec clear_cached_package(String.t(), keyword()) :: :ok
  def clear_cached_package(package_name, opts \\ []) when is_binary(package_name) do
    key = {__MODULE__, :package, package_name, Enum.sort(opts)}

    try do
      :persistent_term.erase(key)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc "Returns all indexed top-level enums."
  @spec enums(t()) :: [RustQ.Syn.Enum.t()]
  def enums(%__MODULE__{files: files}) do
    files
    |> Map.values()
    |> Enum.flat_map(&RustQ.Syn.enums/1)
  end

  @doc "Returns all indexed top-level use aliases."
  @spec uses(t()) :: [RustQ.Syn.Use.t()]
  def uses(%__MODULE__{files: files}) do
    files
    |> Map.values()
    |> Enum.flat_map(&RustQ.Syn.uses/1)
  end

  @doc "Fetches a top-level use alias by alias name."
  @spec use_alias(t(), String.t()) :: {:ok, RustQ.Syn.Use.t()} | :error
  def use_alias(%__MODULE__{} = index, alias) when is_binary(alias) do
    case Enum.find(uses(index), &(&1.alias == alias)) do
      nil -> :error
      use -> {:ok, use}
    end
  end

  @doc "Fetches a top-level use alias by alias name, raising if missing."
  @spec use_alias!(t(), String.t()) :: RustQ.Syn.Use.t()
  def use_alias!(%__MODULE__{} = index, alias) when is_binary(alias) do
    case use_alias(index, alias) do
      {:ok, use} -> use
      :error -> raise "cannot find Rust use alias #{alias}"
    end
  end

  @doc "Returns all indexed top-level static items."
  @spec statics(t()) :: [RustQ.Syn.Static.t()]
  def statics(%__MODULE__{files: files}) do
    files
    |> Map.values()
    |> Enum.flat_map(&RustQ.Syn.statics/1)
  end

  @doc "Fetches a top-level static item by name."
  @spec static(t(), String.t()) :: {:ok, RustQ.Syn.Static.t()} | :error
  def static(%__MODULE__{} = index, name) when is_binary(name) do
    case Enum.find(statics(index), &(&1.name == name)) do
      nil -> :error
      static -> {:ok, static}
    end
  end

  @doc "Returns all indexed top-level type aliases."
  @spec type_aliases(t()) :: [RustQ.Syn.TypeAlias.t()]
  def type_aliases(%__MODULE__{files: files}) do
    files
    |> Map.values()
    |> Enum.flat_map(&RustQ.Syn.type_aliases/1)
  end

  @doc "Fetches a top-level type alias by name."
  @spec type_alias(t(), String.t()) :: {:ok, RustQ.Syn.TypeAlias.t()} | :error
  def type_alias(%__MODULE__{} = index, name) when is_binary(name) do
    case Enum.find(type_aliases(index), &(&1.name == name)) do
      nil -> :error
      alias -> {:ok, alias}
    end
  end

  @doc "Fetches a top-level type alias by name, raising if missing."
  @spec type_alias!(t(), String.t()) :: RustQ.Syn.TypeAlias.t()
  def type_alias!(%__MODULE__{} = index, name) when is_binary(name) do
    case type_alias(index, name) do
      {:ok, alias} -> alias
      :error -> raise "cannot find Rust type alias #{name}"
    end
  end

  @doc "Finds the public Rust type name that aliases a target Rust type name."
  @spec public_type_name(t(), String.t()) :: {:ok, String.t()} | :error
  def public_type_name(%__MODULE__{} = index, target) when is_binary(target) do
    with {:ok, alias} <- target_alias(index, target) do
      {:ok, public_alias_name(index, alias)}
    end
  end

  @doc "Finds the public Rust type name that aliases a target Rust type name, raising if missing."
  @spec public_type_name!(t(), String.t()) :: String.t()
  def public_type_name!(%__MODULE__{} = index, target) when is_binary(target) do
    case public_type_name(index, target) do
      {:ok, name} -> name
      :error -> raise "cannot find public Rust type name for #{target}"
    end
  end

  @doc "Fetches an enum by name."
  @spec enum(t(), String.t()) :: {:ok, RustQ.Syn.Enum.t()} | :error
  def enum(%__MODULE__{} = index, name) when is_binary(name) do
    case Enum.find(enums(index), &(&1.name == name)) do
      nil -> :error
      enum -> {:ok, enum}
    end
  end

  @doc "Fetches an enum by name, raising if missing."
  @spec enum!(t(), String.t()) :: RustQ.Syn.Enum.t()
  def enum!(%__MODULE__{} = index, name) when is_binary(name) do
    case enum(index, name) do
      {:ok, enum} -> enum
      :error -> raise "cannot find Rust enum #{name}"
    end
  end

  @doc "Returns all indexed top-level impl blocks."
  @spec impls(t()) :: [RustQ.Syn.Impl.t()]
  def impls(%__MODULE__{files: files}) do
    files
    |> Map.values()
    |> Enum.flat_map(&RustQ.Syn.impls/1)
  end

  @doc "Returns impl blocks whose target type matches `target`."
  @spec impls(t(), String.t()) :: [RustQ.Syn.Impl.t()]
  def impls(%__MODULE__{} = index, target) when is_binary(target) do
    index
    |> impls()
    |> Enum.filter(&target_matches?(&1.target_ast, target))
  end

  @doc "Returns all methods from impl blocks matching `target`."
  @spec methods(t(), String.t()) :: [RustQ.Syn.Method.t()]
  def methods(%__MODULE__{} = index, target) when is_binary(target) do
    index
    |> impls(target)
    |> Enum.flat_map(& &1.methods)
  end

  @doc "Fetches a method from impl blocks matching `target`."
  @spec method(t(), String.t(), String.t()) :: {:ok, RustQ.Syn.Method.t()} | :error
  def method(%__MODULE__{} = index, target, name) when is_binary(target) and is_binary(name) do
    case Enum.find(methods(index, target), &(&1.name == name)) do
      nil -> :error
      method -> {:ok, method}
    end
  end

  @doc "Fetches a method from impl blocks matching `target`, raising if missing."
  @spec method!(t(), String.t(), String.t()) :: RustQ.Syn.Method.t()
  def method!(%__MODULE__{} = index, target, name) do
    case method(index, target, name) do
      {:ok, method} -> method
      :error -> raise "cannot find Rust method #{target}::#{name}"
    end
  end

  defp target_alias(index, target) do
    case Enum.find(public_aliases(index), &alias_targets?(&1, target)) do
      nil -> :error
      alias -> {:ok, alias}
    end
  end

  defp public_aliases(index) do
    index
    |> aliases()
    |> Enum.filter(&(&1.visibility == :public))
  end

  defp aliases(index), do: uses(index) ++ type_aliases(index)

  defp alias_targets?(%{__struct__: Use, segments: segments}, target),
    do: List.last(segments) == target

  defp alias_targets?(%{__struct__: TypeAlias, type_ast: type}, target),
    do: Type.path?(type, target)

  defp public_alias_name(index, alias),
    do: public_alias_name(index, alias_ref(index, alias), [])

  defp public_alias_name(index, alias_ref, seen) do
    if alias_ref in seen do
      elem(alias_ref, 1)
    else
      seen = [alias_ref | seen]

      case public_reexport(index, alias_ref) do
        nil -> elem(alias_ref, 1)
        reexport -> public_alias_name(index, alias_ref(index, reexport), seen)
      end
    end
  end

  defp public_reexport(index, {_module, name} = alias_ref) do
    index
    |> uses()
    |> Enum.find(fn
      %{__struct__: RustQ.Syn.Use, visibility: :public, segments: segments, alias: alias_name} ->
        segments == Tuple.to_list(alias_ref) and alias_name != name

      _use ->
        false
    end)
  end

  defp alias_ref(index, alias), do: {source_module(index, alias.source_path), alias_name(alias)}

  defp alias_name(%{__struct__: RustQ.Syn.Use, alias: alias}), do: alias
  defp alias_name(%{__struct__: RustQ.Syn.TypeAlias, name: name}), do: name

  defp source_module(
         %__MODULE__{package: %{__struct__: RustQ.Cargo.Package, manifest_path: manifest_path}},
         path
       )
       when is_binary(path) do
    source_module_from_root(Path.dirname(manifest_path), path)
  end

  defp source_module(_index, path) when is_binary(path),
    do: path |> Path.rootname() |> Path.basename()

  defp source_module_from_root(source_root, path)
       when is_binary(source_root) and is_binary(path) do
    path
    |> Path.relative_to(source_root)
    |> Path.rootname()
    |> Path.split()
    |> List.last()
  end

  defp attach_source_path(%{__struct__: RustQ.Syn.File, items: items} = file, path) do
    %{file | items: Enum.map(items, &attach_item_source_path(&1, path))}
  end

  defp attach_item_source_path(%{__struct__: RustQ.Syn.Impl, methods: methods} = item, path) do
    %{item | source_path: path, methods: Enum.map(methods, &%{&1 | source_path: path})}
  end

  defp attach_item_source_path(item, path), do: %{item | source_path: path}

  defp target_matches?(%{__struct__: RustQ.Syn.Type.Path, name: name}, target), do: name == target

  defp target_matches?(%{__struct__: RustQ.Syn.Type.Raw, code: code}, target), do: code == target
  defp target_matches?(_type, _target), do: false
end
