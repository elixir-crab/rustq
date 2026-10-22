defmodule RustQ.Native.Nif do
  @moduledoc false

  use Rustler, otp_app: :rustq, crate: "rustq_nif"

  def parse(_source), do: :erlang.nif_error(:nif_not_loaded)
  def render(_source, _bindings, _splices), do: :erlang.nif_error(:nif_not_loaded)
  def render_ast(_ast), do: :erlang.nif_error(:nif_not_loaded)
  def syn_inspect(_source), do: :erlang.nif_error(:nif_not_loaded)
  def syn_inspect_unstable(_source), do: :erlang.nif_error(:nif_not_loaded)
  def syn_atom_references(_source, _module), do: :erlang.nif_error(:nif_not_loaded)
  def syn_method_references(_source), do: :erlang.nif_error(:nif_not_loaded)
  def syn_method_calls(_source), do: :erlang.nif_error(:nif_not_loaded)
  def syn_enum_variants(_source, _enum_name), do: :erlang.nif_error(:nif_not_loaded)
end
