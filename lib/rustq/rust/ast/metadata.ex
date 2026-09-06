defmodule RustQ.Rust.AST.Metadata do
  @moduledoc "Structured Rust attribute metadata: paths, name/value entries, and nested lists."

  alias RustQ.Rust.AST.Path, as: ASTPath

  defmodule Path do
    @moduledoc "A bare metadata path."
    defstruct [:parts]
    @type t :: %__MODULE__{parts: [atom() | String.t()]}
  end

  defmodule NameValue do
    @moduledoc "A metadata path with a string value."
    defstruct [:parts, :value]
    @type t :: %__MODULE__{parts: [atom() | String.t()], value: String.t()}
  end

  defmodule List do
    @moduledoc "A metadata path containing ordered metadata entries."
    defstruct [:parts, items: []]
    @type t :: %__MODULE__{parts: [atom() | String.t()], items: [RustQ.Rust.AST.Metadata.t()]}
  end

  @type t :: Path.t() | NameValue.t() | List.t()

  @spec normalize(list()) :: [t()]
  def normalize(items) when is_list(items), do: Enum.map(items, &entry/1)

  defp entry(%Path{} = value), do: value
  defp entry(%NameValue{} = value), do: value
  defp entry(%List{} = value), do: %{value | items: normalize(value.items)}
  defp entry(%ASTPath{parts: parts}), do: %Path{parts: parts}

  defp entry({name, items}) when is_list(items),
    do: %List{parts: [name], items: normalize(items)}

  defp entry({name, value}) when is_binary(value) or is_atom(value),
    do: %NameValue{parts: [name], value: to_string(value)}

  defp entry(name) when is_atom(name) or is_binary(name), do: %Path{parts: [name]}
  defp entry(value), do: raise(ArgumentError, "invalid attribute metadata: #{inspect(value)}")
end
