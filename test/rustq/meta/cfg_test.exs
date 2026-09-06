defmodule RustQ.Meta.CfgTest do
  use ExUnit.Case, async: true

  alias RustQ.Meta.AST, as: MetaAST

  @tag :tmp_dir
  test "conditional implementations retain separate clause groups", %{tmp_dir: dir} do
    defmodule Conditional do
      use RustQ.Meta
      @spec value(integer()) :: integer()
      @cfg feature: "extended"
      defrust(value(0), do: 0)
      defrust(value(x), do: x + 1)
      @cfg not: [feature: "extended"]
      defrust(value(x), do: x)
    end

    functions = MetaAST.functions(Conditional)
    assert [enabled, disabled] = functions
    assert MetaAST.function!(Conditional, :value, cfg: [feature: "extended"]) == enabled
    assert MetaAST.function!(Conditional, :value, cfg: [not: [feature: "extended"]]) == disabled

    assert_raise ArgumentError, ~r/multiple implementations/, fn ->
      MetaAST.function!(Conditional, :value)
    end

    source = RustQ.Rust.render_all(functions)
    assert source =~ ~s|#[cfg(feature = "extended")]|
    assert source =~ ~s|#[cfg(not(feature = "extended"))]|
    assert RustQ.valid?(source, "conditional.rs")

    for {flags, expected} <- [{[], "4"}, {["--cfg", ~s|feature="extended"|], "5"}] do
      path = Path.join(dir, "conditional.rs")
      executable = Path.join(dir, "conditional")
      File.write!(path, source <> "\nfn main() { println!(\"{}\", value(4)); }\n")

      assert {_, 0} =
               System.cmd("rustc", [path, "-o", executable] ++ flags, stderr_to_stdout: true)

      assert {output, 0} = System.cmd(executable, [])
      assert String.trim(output) == expected
    end
  end

  test "rejects stacked, dangling, duplicate and mixed conditions" do
    for {body, message} <- [
          {"@cfg feature: \"a\"\n@cfg feature: \"b\"\ndefrust value(x), do: x",
           "only one pending"},
          {"@cfg feature: \"a\"", "must be followed"},
          {"@cfg feature: \"a\"\ndefrust value(x), do: x\n@cfg feature: \"a\"\ndefrust value(x), do: x",
           "duplicate @cfg"},
          {"defrust value(x), do: x\n@cfg feature: \"a\"\ndefrust value(x), do: x", "cannot mix"},
          {"@cfg not: [feature: \"a\", feature: \"b\"]\ndefrust value(x), do: x", "exactly one"}
        ] do
      module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

      assert_raise ArgumentError, ~r/#{message}/, fn ->
        Code.compile_string(
          "defmodule #{inspect(module)} do\nuse RustQ.Meta\n@spec value(integer()) :: integer()\n#{body}\nend"
        )
      end
    end
  end

  @tag :tmp_dir
  test "conditional methods share an implementation and compile in both configurations", %{
    tmp_dir: dir
  } do
    defmodule ConditionalMethods do
      use RustQ.Meta
      alias RustQ.Type, as: R

      defrustimpl Counter do
        @spec shadow(R.ref(Counter.t())) :: integer()
        defrust shadow(counter) do
          total = Enum.reduce([1, 2], 0, fn counter, total -> total + counter * 2 end)
          counter.value + total
        end

        @spec value(R.ref(Counter.t())) :: integer()
        @cfg feature: "extended"
        defrust(value(counter), do: counter.value + 1)
        @cfg not: [feature: "extended"]
        defrust(value(counter), do: counter.value)
      end
    end

    impl = MetaAST.impl!(ConditionalMethods, :Counter)
    assert [_, _, _] = impl.items
    source = RustQ.Rust.render(impl)

    for {flags, expected} <- [{[], "4"}, {["--cfg", ~s|feature="extended"|], "5"}] do
      path = Path.join(dir, "methods.rs")
      executable = Path.join(dir, "methods")

      File.write!(
        path,
        "struct Counter { value: i64 }\n" <>
          source <>
          "\nfn main() { let counter = Counter { value: 4 }; assert_eq!(counter.shadow(), 10); println!(\"{}\", counter.value()); }\n"
      )

      assert {_, 0} =
               System.cmd("rustc", [path, "-o", executable] ++ flags, stderr_to_stdout: true)

      assert {output, 0} = System.cmd(executable, [])
      assert String.trim(output) == expected
    end
  end

  test "nested predicates render structurally" do
    alias RustQ.Rust.AST.Builder, as: A

    function = %RustQ.Rust.AST.Function{
      name: :enabled,
      args: [],
      returns: A.type_path(:bool),
      attrs: [A.attr(:cfg, all: [feature: "a", not: [target_os: "windows"]])],
      body: [A.return_stmt(true)]
    }

    source = RustQ.Rust.render(function)
    assert source =~ ~s|#[cfg(all(feature = "a", not(target_os = "windows")))]|
  end
end
