defmodule RustQ.Rust.AST.Schema do
  @moduledoc """
  Describes every RustQ AST node: its category, fields, and the Rust constant and module
  names the generated native decoders use for it. RustQ's self-hosted code generation
  reads it to build `generated_ast.rs`.
  """

  alias RustQ.Rust.AST
  alias RustQ.Rust.Identifier

  defmodule Node do
    @moduledoc """
    One RustQ AST node's description: its name, Elixir module, category, fields, and the
    Rust constant and module that identify it natively.
    """
    defstruct [:name, :module, :rust_const, :rust_module, :category, fields: []]

    @type t :: %__MODULE__{
            name: atom(),
            module: module(),
            rust_const: atom(),
            rust_module: String.t(),
            category: atom(),
            fields: [{atom(), Macro.t()}]
          }
  end

  @spec nodes() :: [Node.t()]
  def nodes do
    AST.__rustq_ast_modules__()
    |> Enum.map(&node!/1)
  end

  @spec nodes(atom()) :: [Node.t()]
  def nodes(category) do
    Enum.filter(nodes(), &(&1.category == category))
  end

  defp node!(module) do
    %Node{
      name: name(module),
      module: module,
      rust_const: rust_const(module),
      rust_module: rust_module(module),
      category: module.__rustq_ast_category__(),
      fields: fields(module)
    }
  end

  defp fields(module) do
    module
    |> typespec_t()
    |> fields_from_t(module)
  end

  defp typespec_t(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} ->
        Enum.find_value(types, fn
          {:type, {:t, type, _args}} -> type
          _other -> nil
        end) || raise ArgumentError, "missing @type t for #{inspect(module)}"

      :error ->
        raise ArgumentError, "missing typespecs for #{inspect(module)}"
    end
  end

  defp fields_from_t({:type, _line, :map, fields}, module) do
    fields
    |> Enum.map(fn
      {:type, _line, :map_field_exact, [{:atom, _, field}, type]} ->
        {field, type}

      other ->
        raise ArgumentError, "unsupported @type t field in #{inspect(module)}: #{inspect(other)}"
    end)
    |> Enum.reject(fn {field, _type} -> field == :__struct__ end)
  end

  defp fields_from_t({:remote_type, _line, [{:atom, _, module}, {:atom, _, :t}, []]}, module),
    do: fields(module)

  defp fields_from_t(other, module) do
    raise ArgumentError, "unsupported @type t for #{inspect(module)}: #{inspect(other)}"
  end

  defp name(module) do
    Identifier.atom!(Macro.underscore(List.last(Module.split(module))))
  end

  defp rust_const(module) do
    Identifier.atom!(String.upcase(Atom.to_string(name(module))))
  end

  defp rust_module(module), do: Atom.to_string(module)
end
