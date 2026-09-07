defmodule RustQ.Meta.GenericCallbackTest do
  use RustQ.Test, async: true

  defmodule Generated do
    use RustQ.Meta, rust_sources: ["test/fixtures/generic_callback.rs"]
    alias RustQ.Type, as: R

    @spec size(R.ref(String.t())) :: R.usize()
    defrust(size(value), do: value.len())

    @spec run(R.mut_ref(Context.t(String.t())), R.ref(String.t())) :: R.usize()
    defrust run(cx, value) do
      cx.accept(value, fn owner, incoming -> size(owner.clone()) + size(deref(incoming)) end)
    end
  end

  test "specializes foreign callback metadata with concrete argument types" do
    alias RustQ.Binding.Callable
    alias RustQ.Binding.Substitution
    alias RustQ.Rust.AST.Builder, as: A

    file = RustQ.Syn.parse_file!("test/fixtures/generic_callback.rs")
    [method] = RustQ.Syn.methods(file)

    callback =
      method
      |> Callable.from_syn_method()
      |> Map.fetch!(:args)
      |> List.last()
      |> Map.fetch!(:type)

    result =
      Substitution.apply(callback, %{"T" => A.type_path(:String), "U" => A.type_path(:String)})

    assert Enum.map(result.meta.args, & &1.rust) == ["&String", "&String"]
  end

  @tag :tmp_dir
  test "specializes a receiver and method parameter in a compiled callback", %{tmp_dir: tmp_dir} do
    source = rust_source!(Generated)
    assert source =~ "size(&owner.clone())"
    assert source =~ "size(&*incoming)"
    path = Path.join(tmp_dir, "generic_callback.rs")
    executable = Path.join(tmp_dir, "generic_callback")

    File.write!(
      path,
      File.read!("test/fixtures/generic_callback.rs") <>
        source <>
        """
        fn main() {
            let mut cx = Context { owner: String::from("slider") };
            assert_eq!(run(&mut cx, &String::from("value")), 11);
        }
        """
    )

    assert {_, 0} =
             System.cmd("rustc", ["--edition=2021", path, "-o", executable],
               stderr_to_stdout: true
             )

    assert {"", 0} = System.cmd(executable, [])
  end
end
