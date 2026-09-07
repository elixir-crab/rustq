defmodule RustQ.Binding.Callable do
  @moduledoc """
  Normalized callable signature metadata for RustQ lowering and binding generation.

  A callable turns parsed `RustQ.Syn` function/method metadata into a shape that
  Rusty-Elixir lowering can query without depending on raw Syn nodes. Argument
  and return types are converted to `RustQ.Meta.Type` via `RustQ.Spec.from_syn/1`.
  This is the lookup-friendly signature layer needed before type-driven
  propagation inference can decide whether a call should lower with Rust `?`.
  """

  alias RustQ.Meta.Type
  alias RustQ.Native.Descriptor
  alias RustQ.Native.Ref
  alias RustQ.Spec
  alias RustQ.Syn

  defstruct [
    :name,
    :kind,
    :target,
    :target_type,
    :native_ref,
    :source_url,
    :source_path,
    :source_line,
    docs: [],
    args: [],
    returns: nil,
    syn: nil
  ]

  @type arg :: %{name: String.t() | nil, type: Type.t(), syn: Syn.Arg.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          kind: :function | :method,
          target: String.t() | nil,
          native_ref: Ref.t() | nil,
          source_url: String.t() | nil,
          source_path: Path.t() | nil,
          source_line: pos_integer() | nil,
          docs: [String.t()],
          args: [arg()],
          returns: Type.t() | nil,
          syn: Syn.Function.t() | Syn.Method.t() | nil
        }

  @doc "Builds callable metadata from a RustQ `@spec`."
  @spec from_spec(atom(), [Type.t()], Type.t()) :: t()
  def from_spec(name, args, %Type{} = returns) when is_atom(name) and is_list(args) do
    %__MODULE__{
      name: Atom.to_string(name),
      kind: :function,
      args:
        Enum.with_index(args, fn %Type{} = type, index ->
          %{name: "arg#{index}", type: type, syn: nil}
        end),
      returns: returns,
      syn: nil
    }
  end

  @doc "Builds callable metadata from a parsed Rust free function."
  @spec from_syn_function(Syn.Function.t()) :: t()
  def from_syn_function(%Syn.Function{} = function) do
    %__MODULE__{
      name: function.name,
      kind: :function,
      target: function_target(function),
      docs: function.docs,
      args: Enum.map(function.args, &arg/1),
      returns: maybe_type(function.returns_ast),
      source_path: function.source_path,
      source_line: function.source_line,
      syn: function
    }
  end

  @doc "Builds callable metadata from a parsed Rust impl method."
  @spec from_syn_method(Syn.Method.t(), keyword()) :: t()
  def from_syn_method(%Syn.Method{} = method, opts \\ []) do
    %__MODULE__{
      name: method.name,
      kind: :method,
      target: Keyword.get(opts, :target),
      target_type: Keyword.get(opts, :target_type),
      native_ref: Keyword.get(opts, :native_ref),
      source_url: Keyword.get(opts, :source_url),
      docs: method.docs,
      args: Enum.map(method.args, &arg/1),
      returns: maybe_type(method.returns_ast),
      source_path: method.source_path,
      source_line: method.source_line,
      syn: method
    }
  end

  @doc "Builds callable metadata from a resolved native method descriptor."
  @spec from_native_descriptor(Descriptor.t()) :: t()
  def from_native_descriptor(%Descriptor{} = descriptor) do
    descriptor.method
    |> from_syn_method(
      target: descriptor.ref.target,
      native_ref: descriptor.ref,
      source_url: descriptor.source_url
    )
  end

  @doc "Returns the callable return type or raises when the callable returns unit."
  @spec return_type!(t()) :: Type.t()
  def return_type!(%__MODULE__{returns: %Type{} = type}), do: type

  def return_type!(%__MODULE__{name: name}) do
    raise ArgumentError, "callable #{name} has no return type"
  end

  defp function_target(%Syn.Function{module_path: [_ | _] = module_path}),
    do: Enum.join(module_path, "::")

  defp function_target(%Syn.Function{}), do: nil

  defp arg(%Syn.Arg{} = arg) do
    %{name: arg.name, type: Spec.from_syn(arg.type_ast), syn: arg}
  end

  defp maybe_type(nil), do: nil
  defp maybe_type(type), do: Spec.from_syn(type)
end
