defmodule RustQ.Meta.Conditional do
  @moduledoc false

  alias RustQ.Rust.AST

  defstruct [:key, :condition, clauses: []]

  @type t :: %__MODULE__{key: tuple(), condition: AST.Attribute.t() | nil, clauses: [tuple()]}

  @spec groups!([tuple()]) :: [t()]
  def groups!(definitions) do
    {groups, _seen} = Enum.reduce(definitions, {[], %{}}, &group!/2)
    groups |> Enum.reverse() |> Enum.map(&%{&1 | clauses: Enum.reverse(&1.clauses)})
  end

  defp group!({call, body, attrs, mod, impl}, {groups, seen}) do
    {name, args} = head(call)
    key = {name, length(args), mod, impl}
    condition = Enum.find(attrs, &match?(%AST.Attribute{path: [:cfg]}, &1))

    case groups do
      [%__MODULE__{key: ^key} = group | rest] when is_nil(condition) ->
        attrs = if group.condition, do: [group.condition | attrs], else: attrs
        clause = {call, body, attrs, mod, impl}
        {[%{group | clauses: [clause | group.clauses]} | rest], seen}

      _ ->
        validate!(Map.get(seen, key, []), condition, name, length(args))

        group = %__MODULE__{
          key: key,
          condition: condition,
          clauses: [{call, body, attrs, mod, impl}]
        }

        {[group | groups], Map.update(seen, key, [condition], &[condition | &1])}
    end
  end

  defp validate!(conditions, condition, name, arity) do
    if conditions != [] and (is_nil(condition) or nil in conditions),
      do:
        raise(
          ArgumentError,
          "cannot mix unconditional and conditional implementations of #{name}/#{arity}"
        )

    if condition && condition in conditions,
      do: raise(ArgumentError, "duplicate @cfg implementation of #{name}/#{arity}")
  end

  defp head({:when, _, [call, _guard]}), do: head(call)
  defp head({name, _, args}), do: {name, args || []}
end
