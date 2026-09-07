defmodule RustQ.Syn.CallableTraitTest do
  use ExUnit.Case, async: true

  alias RustQ.Binding.Callable
  alias RustQ.Syn

  test "preserves GPUI-shaped callable parameters through normalized callables" do
    source = """
    fn subscribe_in<T, Emitter, Evt>(
        on_event: impl FnMut(&mut T, &Entity<Emitter>, &Evt, &mut Window, &mut Context<T>) + 'static
    ) -> Subscription where Evt: 'static {}
    """

    file = Syn.parse!(source)
    function = Enum.find(file.items, &match?(%Syn.Function{}, &1))
    [arg] = function.args
    [trait] = arg.type_ast.traits
    assert trait.name == "FnMut"

    assert %{args: [_, _, %Syn.Type.Ref{inner: %Syn.Type.Path{name: "Evt"}}, _, _], returns: nil} =
             trait.callable

    normalized = Callable.from_syn_function(function)
    [normalized_arg] = normalized.args
    assert [_, _, _, _, _] = normalized_arg.type.meta.args
    assert normalized_arg.type.meta.returns.kind == :unit
  end

  test "preserves explicit callable output and ordinary generic paths" do
    file = Syn.parse!("fn run(f: impl FnOnce(String) -> Result<u32, Error>, value: Vec<u8>) {}")
    function = Enum.find(file.items, &match?(%Syn.Function{}, &1))
    [callback, vector] = function.args
    [trait] = callback.type_ast.traits
    assert %Syn.Type.Result{} = trait.callable.returns
    assert vector.type_ast.callable == nil
    normalized = Callable.from_syn_function(function)
    assert hd(normalized.args).type.meta.returns.kind == :result
  end
end
