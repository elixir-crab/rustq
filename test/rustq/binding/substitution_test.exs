defmodule RustQ.Binding.SubstitutionTest do
  use ExUnit.Case, async: true
  alias RustQ.Binding.Callable
  alias RustQ.Binding.Substitution
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A

  test "foreign methods preserve impl and method type parameter declarations" do
    file = RustQ.Syn.parse_file!("test/fixtures/generic_callback.rs")
    [method] = RustQ.Syn.methods(file)
    assert method.type_parameters == ["T", "U"]
  end

  test "reclassifies substituted leaves and discards stale generic identity" do
    generic = Type.from_syn(%RustQ.Syn.Type.Path{name: "T", segments: ["T"]})
    result = Substitution.apply(generic, %{"T" => A.type_path(:u32)})
    assert result.kind == :u32
    assert result.rust == "u32"
    refute Map.has_key?(result.meta, :syn_name)
  end

  test "infers nested receiver parameters without guessing concrete names" do
    formal = A.type_path(:Context, generics: [A.type_path(:T)])
    actual = A.type_path(:Context, generics: [A.type_path(:Slider)])
    assert {:ok, bindings} = Substitution.infer(formal, actual, [:T])
    assert bindings == %{"T" => A.type_path(:Slider)}
    assert {:error, _} = Substitution.infer(formal, actual, [])

    assert {:error, {:conflict, "T", _, _}} =
             Substitution.infer(A.type_path(:T), A.type_path(:Other), [:T], bindings)
  end

  test "substitutes callback parameters while leaving unresolved Evt intact" do
    file = RustQ.Syn.parse!("fn listen(f: impl FnMut(&mut Context<T>, &Evt)) {}")
    function = Enum.find(file.items, &match?(%RustQ.Syn.Function{}, &1))
    callable = Callable.from_syn_function(function)
    type = hd(callable.args).type
    result = Substitution.apply(type, %{"T" => A.type_path(:Slider)})
    assert result.rust =~ "Context<Slider>"
    refute result.rust =~ "Context<T>"
    [context, event] = result.meta.args

    assert %AST.TypeRef{inner: %AST.TypePath{generics: [%AST.TypePath{parts: [:Slider]}]}} =
             context.ast

    assert event == Enum.at(type.meta.args, 1)
  end
end
