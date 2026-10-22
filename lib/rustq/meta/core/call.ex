defmodule RustQ.Meta.Core.Call do
  @moduledoc """
  A call in Rusty-Elixir normalized to its module, function, and arguments, so lowering and
  typing match `Kernel` operators, local calls, remote calls, and pipes the same way.
  """

  @kernel_functions [
    :+,
    :-,
    :*,
    :/,
    :==,
    :!=,
    :<,
    :<=,
    :>,
    :>=,
    :and,
    :or,
    :not,
    :div,
    :rem,
    :in,
    :..,
    :abs,
    :min,
    :max,
    :byte_size,
    :length,
    :map_size,
    :elem,
    :put_elem,
    :tuple_size,
    :is_nil
  ]

  defstruct [:module, :function, :args, :meta, :source]

  @type t :: %__MODULE__{
          module: module(),
          function: atom(),
          args: [Macro.t()],
          meta: keyword(),
          source: Macro.t()
        }

  @spec pipe_remote(Macro.t(), Macro.t()) :: {:ok, Macro.t()} | :unsupported
  def pipe_remote(
        left,
        {{:., _dot_meta, [{:__aliases__, _, _parts}, _function]} = target, meta, args}
      )
      when is_list(args) do
    {:ok, {target, meta, [left | args]}}
  end

  def pipe_remote(_left, _right), do: :unsupported

  @spec normalize(Macro.t()) :: {:ok, t()} | :unsupported
  def normalize({{:., _, [{:__aliases__, _, parts}, function]}, meta, args} = source)
      when is_list(parts) and is_atom(function) and is_list(args) do
    {:ok,
     %__MODULE__{
       module: Module.concat(parts),
       function: function,
       args: args,
       meta: meta,
       source: source
     }}
  end

  def normalize({function, meta, args} = source)
      when function in @kernel_functions and is_list(args) do
    {:ok,
     %__MODULE__{
       module: Kernel,
       function: function,
       args: args,
       meta: meta,
       source: source
     }}
  end

  def normalize(_ast), do: :unsupported
end
