defmodule RustQ.Reach.Smells.DefrustMissingSpecTest do
  use RustQ.Test.ReachSmellCase, async: true

  alias RustQ.Reach.Smells.DefrustMissingSpec

  test "detects defrust declarations without specs" do
    source = """
    defmodule Sample.MissingSpec do
      use RustQ.Meta

      defrust decode(term) do
        term
      end
    end
    """

    assert [%{kind: :rustq_defrust_missing_spec}] = run_check(DefrustMissingSpec, source)
  end

  test "accepts typed defrust declarations" do
    source = """
    defmodule Sample.TypedDefrust do
      use RustQ.Meta
      alias RustQ.Type, as: R

      @spec decode(R.term()) :: R.nif_result(R.term())
      defrust decode(term) do
        {:ok, term}
      end
    end
    """

    assert [] = run_check(DefrustMissingSpec, source)
  end
end
