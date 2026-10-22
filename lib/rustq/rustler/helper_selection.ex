defmodule RustQ.Rustler.HelperSelection do
  @moduledoc """
  Selects which generated helpers a Rustler helper generator emits, from its `:include` and
  `:exclude` options.
  """

  @doc """
  Returns the helper names to emit: `:include` (a list, or `:all` for `default_names`,
  which is also the default) without those in `:exclude`.
  """
  @spec names(keyword(), [atom()]) :: [atom()]
  def names(opts, default_names) do
    opts
    |> Keyword.get(:include, default_names)
    |> include_names(default_names)
    |> Kernel.--(List.wrap(Keyword.get(opts, :exclude, [])))
  end

  defp include_names(:all, default_names), do: default_names
  defp include_names(names, _default_names), do: List.wrap(names)
end
