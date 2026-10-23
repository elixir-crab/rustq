defmodule RustQ.Meta.Options do
  @moduledoc """
  The options `use RustQ.Meta` accepts: `:rust_sources`, `:rust_packages`,
  `:callable_modules`, and `:static_types`.
  """

  alias RustQ.Binding.Source
  alias RustQ.Diagnostic

  @type t :: %{
          rust_sources: [Path.t()],
          rust_packages: [Source.rust_package()],
          callable_modules: [module()],
          static_types: keyword(Macro.t())
        }

  @doc "The names of the options `use RustQ.Meta` accepts."
  @spec option_names() :: [atom()]
  def option_names, do: [:rust_sources, :rust_packages, :callable_modules, :static_types]

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

  def validate_rust_sources(nil, _caller), do: {:ok, []}

  def validate_rust_sources(value, caller) do
    with {:ok, paths} <- list_of(compile_time_value(value, caller), &is_binary/1, "string path") do
      {:ok, Source.rust_source_paths(paths)}
    end
  end

  # Paths may be computed when the module compiles, such as `Path.expand("decoder.rs", __DIR__)`
  # for a source shipped beside it, which a path relative to the working directory cannot name.
  defp compile_time_value(value, caller) do
    if Macro.quoted_literal?(value) do
      value
    else
      {evaluated, _binding} = Code.eval_quoted(value, [], caller)
      evaluated
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
        type: {:custom, __MODULE__, :validate_rust_sources, [caller]},
        default: [],
        doc:
          "Rust source path or paths to inspect for external callable metadata, evaluated " <>
            "when the module compiles; relative paths are relative to the working directory"
      ],
      rust_packages: [
        type: {:custom, __MODULE__, :validate_rust_packages, []},
        default: [],
        doc: "Cargo package name or {package_name, opts} entries to inspect for callable metadata"
      ],
      callable_modules: [
        type: {:custom, __MODULE__, :validate_callable_modules, [caller]},
        default: [],
        doc: "RustQ modules whose __rustq_callables__/0 metadata should be imported"
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
