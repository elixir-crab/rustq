defmodule RustQ.Reach.Smells.BlocklessDefrustmodTest do
  use RustQ.Test.ReachSmellCase, async: true

  alias RustQ.Reach.Smells.BlocklessDefrustmod

  test "detects blockless defrustmod declarations" do
    source = """
    defmodule Sample.BlocklessMod do
      use RustQ.Meta

      defrustmod(GeneratedOpts, as: :generated_opts)
    end
    """

    assert [%{kind: :rustq_blockless_defrustmod}] = run_check(BlocklessDefrustmod, source)
  end

  test "ignores block-form defrustmod declarations" do
    source = """
    defmodule Sample.BlockMod do
      use RustQ.Meta

      defrustmod Helpers, as: :helpers do
        defrust identity(value) do
          value
        end
      end
    end
    """

    assert [] = run_check(BlocklessDefrustmod, source)
  end
end
