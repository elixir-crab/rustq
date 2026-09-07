defmodule RustQ.Meta.UnknownReceiverTest do
  use RustQ.Test, async: true

  defmodule Generated do
    use RustQ.Meta, rust_sources: ["test/fixtures/generic_callback.rs"]
    alias RustQ.Type, as: R

    @spec run() :: R.unit()
    defrust run() do
      case unknown_receiver() do
        {:ok, receiver} -> receiver.accept(value, callback)
        {:error, _} -> :ok
      end

      :ok
    end

    @spec mutate(R.mut_ref(R.vec(integer()))) :: R.unit()
    defrust mutate(values) do
      borrowed = mut_ref(deref(values))
      borrowed.push(1)
      :ok
    end
  end

  test "unknown receivers do not gain mutable bindings from method names" do
    source = rust_source!(Generated, :run)
    refute source =~ "mut receiver"
  end

  test "a mutable reference binding need not itself be mutable" do
    source = rust_source!(Generated, :mutate)
    assert source =~ "let borrowed = &mut *values"
    refute source =~ "let mut borrowed"
  end
end
