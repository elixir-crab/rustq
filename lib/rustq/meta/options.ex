defmodule RustQ.Meta.Options do
  @moduledoc """
  The options `use RustQ.Meta` accepts: `:rust_sources`, `:provides`, `:rust_packages`,
  `:callable_modules`, and `:static_types`.
  """

  alias RustQ.Binding.Source
  alias RustQ.Diagnostic

  @type t :: %{
          optional(:provides) => [Path.t()],
          rust_sources: [Path.t()] | {:quoted, Macro.t()},
          rust_packages: [Source.rust_package()],
          callable_modules: [module()],
          static_types: keyword(Macro.t())
        }

  @doc "The names of the options `use RustQ.Meta` accepts."
  @spec option_names() :: [atom()]
  def option_names,
    do: [:rust_sources, :provides, :rust_packages, :callable_modules, :static_types]

  @doc "Validates and normalizes options passed to `use RustQ.Meta`."
  @spec validate!(keyword(), Macro.Env.t()) :: t()
  def validate!(opts, %Macro.Env{} = caller) when is_list(opts) do
    case NimbleOptions.validate(opts, schema(caller)) do
      {:ok, validated} ->
        Map.new(validated)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        Diagnostic.defrust(
          :invalid_meta_option,
          error.value,
          Exception.message(error),
          details: %{key: diagnostic_key(error), keys_path: error.keys_path, value: error.value}
        )
    end
  end

  def validate!(opts, _caller) do
    Diagnostic.defrust(:invalid_meta_option, opts, "RustQ.Meta options must be a keyword list",
      details: %{value: opts}
    )
  end

  def validate_rust_sources(nil), do: {:ok, []}

  # A path that is not a literal, such as a module attribute or a function call, is resolved
  # where `use RustQ.Meta` places it in the module body; see `rust_source_paths!/1`.
  def validate_rust_sources(value) do
    if Macro.quoted_literal?(value) do
      with {:ok, paths} <- list_of(value, &is_binary/1, "string path") do
        {:ok, Source.rust_source_paths(paths)}
      end
    else
      {:ok, {:quoted, value}}
    end
  end

  @doc """
  Returns `rust_sources` given as an expression, such as `[@source]`, once the module body
  has evaluated it. Relative paths are relative to the working directory.
  """
  @spec rust_source_paths!(term()) :: [Path.t()]
  def rust_source_paths!(value) do
    case list_of(value, &is_binary/1, "string path") do
      {:ok, paths} ->
        Source.rust_source_paths(paths)

      {:error, message} ->
        Diagnostic.defrust(
          :invalid_meta_option,
          value,
          "invalid value for :rust_sources option: #{message}",
          details: %{key: :rust_sources, value: value}
        )
    end
  end

  def validate_provides(nil, _caller), do: {:ok, []}

  # Rust a module provides ships beside it, so its paths are relative to the module's file.
  def validate_provides(value, caller) do
    with {:ok, paths} <- list_of(value, &is_binary/1, "string path") do
      {:ok, Enum.map(paths, &Path.expand(&1, Path.dirname(caller.file)))}
    end
  end

  def validate_rust_packages(nil), do: {:ok, []}

  def validate_rust_packages(value) do
    list_of(value, &valid_rust_package?/1, "package name or {package_name, opts}")
  end

  def validate_callable_modules(nil, _caller), do: {:ok, []}

  def validate_callable_modules(value, caller) do
    with {:ok, modules} <- list_of(value, &valid_callable_module_ast?/1, "module alias") do
      expanded = Enum.map(modules, &Macro.expand(&1, caller))

      if Enum.all?(expanded, &is_atom/1) do
        {:ok, expanded}
      else
        {:error, "expected a module alias or list of module aliases"}
      end
    end
  end

  def validate_static_types(nil), do: {:ok, []}

  def validate_static_types(value) when is_list(value) do
    if Enum.all?(value, fn {name, _type_ast} -> is_atom(name) end) do
      {:ok, value}
    else
      {:error, "expected keyword list of static name to RustQ type spec"}
    end
  end

  def validate_static_types(_value),
    do: {:error, "expected keyword list of static name to RustQ type spec"}

  defp diagnostic_key(%NimbleOptions.ValidationError{} = error) do
    error
    |> Map.fetch!(:key)
    |> List.wrap()
    |> List.last()
  end

  defp schema(caller) do
    [
      rust_sources: [
        type: {:custom, __MODULE__, :validate_rust_sources, []},
        default: [],
        doc:
          "Rust source path or paths to inspect for external callable metadata, as literals " <>
            "or an expression such as a module attribute; relative paths are relative to the " <>
            "working directory"
      ],
      provides: [
        type: {:custom, __MODULE__, :validate_provides, [caller]},
        doc:
          "Rust source path or paths the module emits as they are, relative to the module's " <>
            "file; their functions, methods, and types join the module's exports. Without " <>
            "it, a module provides the `.rs` file beside it named as its own file is"
      ],
      rust_packages: [
        type: {:custom, __MODULE__, :validate_rust_packages, []},
        default: [],
        doc: "Cargo package name or {package_name, opts} entries to inspect for callable metadata"
      ],
      callable_modules: [
        type: {:custom, __MODULE__, :validate_callable_modules, [caller]},
        default: [],
        doc:
          "RustQ modules whose __rustq_callables__/0 metadata should be imported; modules " <>
            "named through `alias` in specs and `defrust` bodies are imported without it"
      ],
      static_types: [
        type: {:custom, __MODULE__, :validate_static_types, []},
        default: [],
        doc: "Keyword list of generated Rust static item names to RustQ type specs"
      ]
    ]
  end

  defp list_of(value, valid?, description) do
    values = List.wrap(value)

    if Enum.all?(values, valid?) do
      {:ok, values}
    else
      {:error, "expected #{description} or list of #{description}s"}
    end
  end

  defp valid_rust_package?(package) when is_binary(package), do: true
  defp valid_rust_package?({package, opts}) when is_binary(package) and is_list(opts), do: true
  defp valid_rust_package?(_package), do: false

  defp valid_callable_module_ast?(module) when is_atom(module), do: true
  defp valid_callable_module_ast?({:__aliases__, _meta, parts}) when is_list(parts), do: true
  defp valid_callable_module_ast?(_module), do: false
end
