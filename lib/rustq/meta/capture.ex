defmodule RustQ.Meta.Capture do
  @moduledoc """
  Capture shorthand in Rusty-Elixir, rewritten as the anonymous function it stands for so it
  lowers wherever a closure does.
  """

  @doc """
  Rewrites capture shorthand such as `&(&1 + &2)` as the anonymous function it stands for,
  `fn value1, value2 -> value1 + value2 end`; other expressions, including `&fun/1`, are kept.
  """
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:&, _meta, [{:/, _, [_function, arity]}]} = capture) when is_integer(arity),
    do: capture

  def expand({:&, meta, [body]}) do
    count =
      body
      |> Macro.prewalker()
      |> Enum.reduce(0, fn
        {:&, _, [index]}, count when is_integer(index) -> max(count, index)
        _node, count -> count
      end)

    names = argument_names(count, variables(body))

    body =
      Macro.prewalk(body, fn
        {:&, _, [index]} when is_integer(index) -> Macro.var(Enum.at(names, index - 1), nil)
        other -> other
      end)

    {:fn, meta, [{:->, meta, [Enum.map(names, &Macro.var(&1, nil)), body]}]}
  end

  def expand(expression), do: expression

  # `value` for one argument and `value1`, `value2`, … for several, unless the body already
  # uses that name for a variable it closes over.
  defp argument_names(1, used), do: [unused(:value, used)]

  defp argument_names(count, used),
    do: for(index <- 1..count//1, do: unused(:"value#{index}", used))

  defp unused(name, used),
    do: if(MapSet.member?(used, name), do: unused(:"#{name}_", used), else: name)

  defp variables(body) do
    for {name, _meta, context} <- Macro.prewalker(body),
        is_atom(name) and is_atom(context),
        into: MapSet.new(),
        do: name
  end
end
