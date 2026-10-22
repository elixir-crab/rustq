defmodule RustQ.Reach.Smells.LowLevelControlFlowTest do
  use RustQ.Test.ReachSmellCase, async: true

  alias RustQ.Reach.Smells.LowLevelControlFlow

  test "detects low-level control flow in defrust bodies" do
    source = """
    defmodule Sample.LowLevel do
      use RustQ.Meta

      defrust decode(value) do
        return!(value)
      end
    end
    """

    assert [%{kind: :rustq_low_level_control_flow}] = run_check(LowLevelControlFlow, source)
  end
end
