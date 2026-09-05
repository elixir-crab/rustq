defmodule RustQ.Meta.Lower.Stdlib do
  @moduledoc false

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  defmodule Context do
    @moduledoc false

    defstruct [
      :lower,
      :lower_expected,
      :lower_binary_operand,
      :lower_closure,
      :lower_typed_closure,
      :lower_closure_body,
      :lower_capture,
      :closure_arg,
      :type_of,
      :expected
    ]

    @type t :: %__MODULE__{
            lower: (Macro.t() -> term()),
            lower_expected: (Macro.t(), term() -> term()),
            lower_binary_operand: (Macro.t() -> term()),
            lower_closure: ([Macro.t()], Macro.t() -> term()),
            lower_typed_closure: ([Macro.t()], Macro.t(), Type.t() | nil -> term()),
            lower_closure_body: (Macro.t(), term() -> term()),
            lower_capture: (Macro.t() -> term()),
            closure_arg: (Macro.t() -> atom()),
            type_of: (Macro.t() -> term()),
            expected: Type.t() | nil
          }
  end

  @spec shape_type(Type.t() | nil) :: Type.t() | nil
  def shape_type(%Type{kind: kind} = type) when kind in [:nif_result, :result],
    do: Type.inner(type)

  def shape_type(type), do: type

  @spec evaluated_constant(Macro.t(), term(), Context.t()) :: {:ok, AST.expr()}
  def evaluated_constant(argument, value, context) do
    evaluated =
      case context.type_of.(argument) do
        %Type{kind: kind} = type when kind in [:nif_result, :result] ->
          context.lower_expected.(argument, Type.inner(type))

        _type ->
          context.lower.(argument)
      end

    {:ok,
     %AST.BlockExpr{
       body: [
         %AST.Let{pattern: %AST.PatWildcard{}, expr: evaluated},
         %AST.Return{expr: %AST.Literal{value: value}}
       ]
     }}
  end

  @spec lower(Macro.t(), Context.t()) :: {:ok, term()} | :unsupported
  def lower(ast, %Context{} = context) do
    with {:ok, %Call{} = call} <- Call.normalize(ast) do
      lower_call(call, context)
    end
  end

  @spec lower!(Macro.t(), Context.t()) :: term()
  def lower!(ast, %Context{} = context) do
    case lower(ast, context) do
      {:ok, lowered} ->
        lowered

      :unsupported ->
        Diagnostic.lower(
          :unsupported_stdlib_call,
          ast,
          "unsupported Elixir standard-library call in defrust",
          suggestion:
            "Use a documented Kernel/Enum/List/Map/String/Tuple/Range form or add an explicit Rust adapter."
        )
    end
  end

  defmodule TypeContext do
    @moduledoc false

    defstruct [:type_of, :type_with_vars]

    @type t :: %__MODULE__{
            type_of: (Macro.t() -> term()),
            type_with_vars: (Macro.t(), map() -> term())
          }
  end

  @spec synth(Macro.t(), TypeContext.t()) :: {:ok, term()} | :unsupported
  def synth(ast, %TypeContext{} = context) do
    with {:ok, %Call{} = call} <- Call.normalize(ast) do
      synth_call(call, context)
    end
  end

  @spec nonnegative_count(Macro.t(), Context.t()) :: {:ok, AST.expr()} | :unsupported
  def nonnegative_count(count, %Context{} = context) when is_integer(count) and count >= 0,
    do: {:ok, context.lower.(count)}

  def nonnegative_count(count, %Context{} = context) do
    case context.type_of.(count) do
      %Type{kind: kind} when kind in [:u8, :u16, :u32, :u64, :usize] ->
        {:ok, %AST.Cast{expr: context.lower.(count), type: %AST.TypePath{parts: [:usize]}}}

      _type ->
        :unsupported
    end
  end

  defp lower_call(%Call{module: Kernel, function: function} = call, context)
       when function in [:.., :in],
       do: RustQ.Meta.Lower.Range.lower(call, context)

  defp lower_call(%Call{module: Kernel} = call, context),
    do: RustQ.Meta.Lower.Kernel.lower(call, context)

  defp lower_call(%Call{module: Enum} = call, context),
    do: RustQ.Meta.Lower.Enum.lower(call, context)

  defp lower_call(%Call{module: List} = call, context),
    do: RustQ.Meta.Lower.List.lower(call, context)

  defp lower_call(%Call{module: Map} = call, context),
    do: RustQ.Meta.Lower.Map.lower(call, context)

  defp lower_call(%Call{module: String} = call, context),
    do: RustQ.Meta.Lower.String.lower(call, context)

  defp lower_call(%Call{module: Tuple} = call, context),
    do: RustQ.Meta.Lower.Tuple.lower(call, context)

  defp lower_call(%Call{module: Range} = call, context),
    do: RustQ.Meta.Lower.Range.lower(call, context)

  defp lower_call(%Call{}, _context), do: :unsupported

  defp synth_call(%Call{module: Kernel, function: function} = call, context)
       when function in [:.., :in],
       do: RustQ.Meta.Lower.Range.synth(call, context)

  defp synth_call(%Call{module: Kernel} = call, context),
    do: RustQ.Meta.Lower.Kernel.synth(call, context)

  defp synth_call(%Call{module: Enum} = call, context),
    do: RustQ.Meta.Lower.Enum.synth(call, context)

  defp synth_call(%Call{module: List} = call, context),
    do: RustQ.Meta.Lower.List.synth(call, context)

  defp synth_call(%Call{module: Map} = call, context),
    do: RustQ.Meta.Lower.Map.synth(call, context)

  defp synth_call(%Call{module: String} = call, context),
    do: RustQ.Meta.Lower.String.synth(call, context)

  defp synth_call(%Call{module: Tuple} = call, context),
    do: RustQ.Meta.Lower.Tuple.synth(call, context)

  defp synth_call(%Call{module: Range} = call, context),
    do: RustQ.Meta.Lower.Range.synth(call, context)

  defp synth_call(%Call{}, _context), do: :unsupported
end
