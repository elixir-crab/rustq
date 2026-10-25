defmodule RustQ.Meta.ProvidesTest do
  use RustQ.Test, async: true

  import ExUnit.CaptureIO

  alias RustQ.Meta.ProvidedCase

  test "the module's Rust file in templates/ is provided" do
    assert ProvidedCase.__rustq_source__() ==
             "test/support/templates/provided_case.rs" |> File.read!() |> String.trim_trailing()
  end

  test "provided functions and methods are exported" do
    callables = Enum.map(ProvidedCase.__rustq_callables__(), &{&1.kind, &1.target, &1.name})

    assert {:function, nil, "decode_entry"} in callables
    assert {:method, "Entry", "get"} in callables
  end

  test "provided types are exported as Elixir types" do
    assert %{rust: "Entry"} = ProvidedCase.__rustq_types__()[{:entry, 0}]
    assert {:ok, [{:type, {:entry, _, []}}]} = Code.Typespec.fetch_types(ProvidedCase)
  end

  test "provides names other files" do
    defmodule NamedProviderCase do
      use RustQ.Meta, provides: ["../../support/templates/provided_case.rs"]
    end

    assert NamedProviderCase.__rustq_source__() == ProvidedCase.__rustq_source__()
  end

  test "a module whose file has another name provides nothing" do
    defmodule UnnamedProviderCase do
      use RustQ.Meta
    end

    assert UnnamedProviderCase.__rustq_source__() == ""
  end

  test "recompiles when its Rust file appears or goes" do
    refute ProvidedCase.__mix_recompile__?()
  end

  test "a provider named through alias is imported" do
    defmodule AliasedProviderCase do
      use RustQ.Meta

      alias RustQ.Meta.ProvidedCase, as: Runtime
      alias RustQ.Type, as: R

      @spec first(R.slice(R.u8())) :: R.nif_result(R.option(R.u32()))
      defrust first(bytes) do
        entry = Runtime.decode_entry(bytes)
        {:ok, entry.get(0)}
      end

      @spec second(R.ref(Runtime.entry())) :: R.option(R.u32())
      defrust(second(entry), do: entry.get(1))
    end

    source = AliasedProviderCase.__rustq_source__()

    assert source =~ "let entry = decode_entry(bytes)?;"
    assert source =~ "fn second(entry: &Entry) -> Option<u32>"
  end

  test "an alias used only in a body is used" do
    warnings =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule RustQ.Meta.ProvidesTest.BodyAliasCase do
          use RustQ.Meta

          alias RustQ.Meta.ProvidedCase
          alias RustQ.Type, as: R

          @spec count(R.slice(R.u8())) :: R.nif_result(R.option(R.u32()))
          defrust count(bytes), do: {:ok, ProvidedCase.decode_entry(bytes).get(0)}
        end
        """)
      end)

    refute warnings =~ "unused alias"
  end
end
