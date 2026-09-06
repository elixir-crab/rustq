defmodule RustQ.Meta.Attrs do
  @moduledoc false

  alias RustQ.Rust.AST

  def take_pending(module) do
    cfg =
      case Module.get_attribute(module, :cfg) do
        nil -> nil
        [] -> nil
        [condition] -> condition
        _stacked -> raise ArgumentError, "only one pending @cfg is allowed; use all or any"
      end

    Module.delete_attribute(module, :cfg)
    nif = Module.get_attribute(module, :nif)
    allow = Module.get_attribute(module, :allow) |> List.wrap() |> Enum.reverse()
    Module.delete_attribute(module, :nif)
    Module.delete_attribute(module, :allow)

    []
    |> add_nif_attr(nif)
    |> Kernel.++(Enum.map(allow, &allow_attr/1))
    |> add_cfg(cfg, nif)
  end

  defp add_cfg(attrs, nil, _nif), do: attrs

  defp add_cfg(attrs, cfg, _nif) do
    validate_cfg!(cfg)
    attrs ++ [%AST.Attribute{path: [:cfg], args: cfg}]
  end

  defp validate_cfg!([{key, predicates}])
       when key in [:not, :all, :any] and is_list(predicates) do
    if key == :not and not match?([_], predicates),
      do: raise(ArgumentError, "@cfg not requires exactly one predicate")

    Enum.each(predicates, fn predicate -> validate_cfg!([predicate]) end)
  end

  defp validate_cfg!([{key, value}]) when is_atom(key) and is_binary(value), do: :ok
  defp validate_cfg!([flag]) when is_atom(flag), do: :ok

  defp validate_cfg!(_cfg),
    do: raise(ArgumentError, "@cfg requires one predicate; combine predicates with all or any")

  def current_rust_mod(module), do: Module.get_attribute(module, :rustq_current_rust_mod)
  def current_rust_impl(module), do: Module.get_attribute(module, :rustq_current_rust_impl)

  defp add_nif_attr(attrs, nil), do: attrs
  defp add_nif_attr(attrs, false), do: attrs
  defp add_nif_attr(attrs, true), do: attrs ++ [%AST.Attribute{path: [:rustler, :nif]}]

  defp add_nif_attr(attrs, opts) when is_list(opts),
    do: attrs ++ [%AST.Attribute{path: [:rustler, :nif], args: normalize_nif_opts(opts)}]

  defp normalize_nif_opts(opts) do
    case Keyword.fetch(opts, :schedule) do
      {:ok, :dirty_cpu} -> Keyword.put(opts, :schedule, "DirtyCpu")
      {:ok, :dirty_io} -> Keyword.put(opts, :schedule, "DirtyIo")
      _other -> opts
    end
  end

  defp allow_attr(values), do: %AST.Attribute{path: [:allow], args: List.wrap(values)}
end
