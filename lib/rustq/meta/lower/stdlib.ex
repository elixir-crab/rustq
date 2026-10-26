defmodule RustQ.Meta.Lower.Stdlib do
  @moduledoc """
  Lowers calls to Elixir's standard library to Rust that keeps their semantics: a call to an
  Elixir module goes to the module lowering it, named after it (`RustQ.Meta.Lower.Enum` for
  `Enum`), which implements `RustQ.Meta.Lower.Stdlib.Lowering`. Calls whose semantics Rust
  cannot preserve are rejected.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Lower.Stdlib.Lowering
  alias RustQ.Meta.Lower.Stdlib.Lowering.{Context, TypeContext}

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
            "Use a documented Kernel/Enum/List/Map/MapSet/String/Tuple/Range form or add an explicit Rust adapter."
        )
    end
  end

  @spec synth(Macro.t(), TypeContext.t()) :: {:ok, term()} | :unsupported
  def synth(ast, %TypeContext{} = context) do
    with {:ok, %Call{} = call} <- Call.normalize(ast) do
      synth_call(call, context)
    end
  end

  defp lower_call(%Call{} = call, context) do
    case lowering(call.module) do
      nil -> :unsupported
      lowering -> lowering.lower(call, context)
    end
  end

  defp synth_call(%Call{} = call, context) do
    case lowering(call.module) do
      nil -> :unsupported
      lowering -> lowering.synth(call, context)
    end
  end

  # The module named after an Elixir module that lowers it, such as `RustQ.Meta.Lower.Enum`
  # for `Enum`. Only Elixir's own modules are looked up, so an alias a body names never is.
  # Each module's answer is kept, since a body names the same few modules many times.
  defp lowering(module) do
    case :persistent_term.get({__MODULE__, module}, :unknown) do
      :unknown ->
        lowering = find_lowering(module)
        :persistent_term.put({__MODULE__, module}, lowering)
        lowering

      lowering ->
        lowering
    end
  end

  defp find_lowering(module) do
    lowering = Module.concat(RustQ.Meta.Lower, module)

    if Application.get_application(module) == :elixir and Lowering.lowering?(lowering),
      do: lowering
  end
end
