defmodule RustQ.Meta.StandardPointerTest do
  use RustQ.Test, async: true
  alias RustQ.Meta.StandardPointer
  alias RustQ.Meta.Type

  defmodule Generated do
    use RustQ.Meta, rust_sources: ["test/fixtures/generic_callback.rs"]
    alias RustQ.Type, as: R

    @spec lock(R.ref(Std.Sync.Arc.t(Std.Sync.Mutex.t(Context.t(String.t()))))) :: R.unit()
    defrust lock(shared) do
      case shared.lock() do
        {:ok, guard} -> guard.accept(value, callback)
        {:error, _} -> :ok
      end

      :ok
    end
  end

  test "infers mutability through a known standard Arc Mutex guard" do
    assert rust_source!(Generated, :lock) =~ "if let Ok(mut guard)"
  end

  test "does not treat arbitrary names as standard pointer types" do
    assert StandardPointer.lock_result(Type.parse(quote(do: Arc.t(Mutex.t(integer()))), %{})) ==
             nil
  end
end
