defmodule RustQ.Meta.Lower.Stdlib.Lowering do
  @moduledoc """
  The behaviour of a module lowering one Elixir standard-library module, and the helpers such
  a module lowers and types its arguments with.

  `RustQ.Meta.Lower.Stdlib` dispatches a call to `Enum` to `RustQ.Meta.Lower.Enum`, a call to
  `Map` to `RustQ.Meta.Lower.Map`, and so on: the module named after the Elixir module, when
  it implements this behaviour. `use` this module to implement it and import the helpers:

      defmodule RustQ.Meta.Lower.List do
        use RustQ.Meta.Lower.Stdlib.Lowering

        @impl true
        def lower(%Call{function: :first, args: [list]}, %Context{} = context),
          do: {:ok, list |> lowered(context) |> A.method(:into_iter) |> A.method(:next)}
      end

  A lowering returns `:unsupported` for a call it does not lower, and `RustQ.Meta.Lower.Stdlib`
  reports it.
  """

  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A

  defmodule Context do
    @moduledoc """
    What a standard-library lowering knows: the lowering environment of the call, and the
    type the call is expected to produce.
    """

    defstruct [:env, :expected]

    @type t :: %__MODULE__{env: Lower.Env.t(), expected: Type.t() | nil}
  end

  defmodule TypeContext do
    @moduledoc "What a standard-library lowering knows when it types a call."

    defstruct [:env]

    @type t :: %__MODULE__{env: Typing.Env.t()}
  end

  @doc "Lowers `call`, or returns `:unsupported` for a call this module does not lower."
  @callback lower(Call.t(), Context.t()) :: {:ok, AST.expr()} | :unsupported

  @doc "Types `call`, or returns `:unsupported` for a call this module does not type."
  @callback synth(Call.t(), TypeContext.t()) :: {:ok, Type.t()} | :unsupported

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      import unquote(__MODULE__), except: [lowering?: 1]

      alias RustQ.Meta.Core.Call
      alias unquote(__MODULE__).{Context, TypeContext}
      alias RustQ.Rust.AST
      alias RustQ.Rust.AST.Builder, as: A
    end
  end

  @doc "Whether `module` lowers an Elixir standard-library module."
  @spec lowering?(module()) :: boolean()
  def lowering?(module) do
    # `ensure_compiled` waits for a lowering RustQ itself is still compiling.
    match?({:module, _}, Code.ensure_compiled(module)) and
      __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end

  @doc "`expression`, lowered."
  @spec lowered(Macro.t(), Context.t()) :: AST.expr()
  def lowered(expression, %Context{env: env}), do: Lower.lower_expr(expression, env)

  @doc "`expression`, lowered to produce a value of `expected`."
  @spec lowered(Macro.t(), Type.t() | nil, Context.t()) :: AST.expr()
  def lowered(expression, expected, %Context{env: env}),
    do: Lower.lower_expr(expression, expected, env)

  @doc "`expression`, lowered as an operand: a fallible one propagates its error with `?`."
  @spec operand(Macro.t(), Context.t()) :: AST.expr()
  def operand(expression, %Context{env: env}), do: Lower.lower_binary_operand(expression, env)

  @doc "A closure taking `args` and returning `body`, lowered."
  @spec closure([Macro.t()], Macro.t(), Context.t()) :: AST.expr()
  def closure(args, body, %Context{env: env}), do: Lower.lower_closure_args(args, body, env)

  @doc "A closure taking `args` and returning `body` as a value of `returns`, lowered."
  @spec closure([Macro.t()], Macro.t(), Type.t() | nil, Context.t()) :: AST.expr()
  def closure(args, body, returns, %Context{env: env}),
    do: Lower.lower_closure_args(args, body, env, returns)

  @doc "A closure's `body`, lowered to return a value of `returns`."
  @spec closure_body(Macro.t(), Type.t() | nil, Context.t()) :: AST.expr()
  def closure_body(body, returns, %Context{env: env}),
    do: Lower.lower_closure_body(body, returns, env)

  @doc "A closure argument, as a Rust closure argument."
  @spec closure_arg(Macro.t()) :: atom() | AST.pat()
  defdelegate closure_arg(arg), to: Lower, as: :closure_arg!

  @doc "A captured named function, as the Rust path of that function."
  @spec capture(Macro.t(), Context.t()) :: AST.expr()
  def capture(function, %Context{env: env}), do: Lower.lower_function_capture(function, env)

  @doc "The type of `expression`, or nil when it is not known."
  @spec type_of(Macro.t(), Context.t() | TypeContext.t()) :: Type.t() | nil
  def type_of(expression, %Context{env: env}), do: Typing.synth(expression, Lower.typing_env(env))
  def type_of(expression, %TypeContext{env: env}), do: Typing.synth(expression, env)

  @doc "The type of `expression` where `vars` are bound to the given types."
  @spec type_with_vars(Macro.t(), %{optional(atom()) => Type.t()}, TypeContext.t()) ::
          Type.t() | nil
  def type_with_vars(expression, vars, %TypeContext{env: env}),
    do: Typing.synth(expression, %{env | vars: Map.merge(env.vars, vars)})

  @doc "Whether `collection` is still in use after this use of it; see `RustQ.Meta.Ownership`."
  @spec in_use?(Macro.t(), Context.t()) :: boolean()
  def in_use?(collection, %Context{env: env}), do: Lower.in_use?(collection, env)

  @doc "The type a call shapes its value as: a fallible call's success type, and others' own."
  @spec shape_type(Type.t() | nil) :: Type.t() | nil
  def shape_type(%Type{kind: kind} = type) when kind in [:nif_result, :result],
    do: Type.inner(type)

  def shape_type(type), do: type

  @doc "`argument` evaluated for its effects, then the constant `value`."
  @spec evaluated_constant(Macro.t(), term(), Context.t()) :: {:ok, AST.expr()}
  def evaluated_constant(argument, value, %Context{} = context) do
    evaluated =
      case type_of(argument, context) do
        %Type{kind: kind} = type when kind in [:nif_result, :result] ->
          lowered(argument, Type.inner(type), context)

        _type ->
          lowered(argument, context)
      end

    {:ok,
     A.block_expr([
       %AST.Let{pattern: %AST.PatWildcard{}, expr: evaluated},
       A.return_stmt(A.lit(value))
     ])}
  end

  @doc "A Rust count as Elixir's integer, an `i64`, unless the call is expected to produce a `usize`."
  @spec integer_count(AST.expr(), Context.t()) :: AST.expr()
  def integer_count(count, %Context{expected: %Type{kind: :usize}}), do: count
  def integer_count(count, %Context{}), do: A.cast(count, A.type(:i64))

  @doc "`count` as a `usize`, when it is a literal or unsigned count that cannot be negative."
  @spec nonnegative_count(Macro.t(), Context.t()) :: {:ok, AST.expr()} | :unsupported
  def nonnegative_count(count, %Context{} = context) when is_integer(count) and count >= 0,
    do: {:ok, lowered(count, context)}

  def nonnegative_count(count, %Context{} = context) do
    case type_of(count, context) do
      %Type{kind: :usize} ->
        {:ok, lowered(count, context)}

      %Type{kind: kind} when kind in [:u8, :u16, :u32, :u64] ->
        {:ok, A.cast(lowered(count, context), A.type(:usize))}

      _type ->
        :unsupported
    end
  end
end
