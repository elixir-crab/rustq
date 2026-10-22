defmodule RustQ.Reach.Smells.TrivialDefrustWrapperTest do
  use RustQ.Test.ReachSmellCase, async: true

  alias RustQ.Reach.Smells.TrivialDefrustWrapper

  test "detects trivial defrust wrappers" do
    source = """
    defmodule Sample.Wrapper do
      use RustQ.Meta

      defrust skip(decoder) do
        unwrap!(decoder.read_var_int64())
        :ok
      end
    end
    """

    assert [%{kind: :rustq_trivial_defrust_wrapper}] = run_check(TrivialDefrustWrapper, source)
  end

  test "does not flag meaningful defrust bodies as trivial wrappers" do
    source = """
    defmodule Sample.NotWrapper do
      use RustQ.Meta

      defrust skip(decoder, remaining) do
        if remaining == 0 do
          :ok
        else
          skip(decoder, remaining - 1)
        end
      end
    end
    """

    assert [] = run_check(TrivialDefrustWrapper, source)
  end
end
