defmodule RustQ.Test.ReachSmellCase do
  @moduledoc """
  Runs a RustQ Reach smell check over Elixir source written to a temporary file.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import RustQ.Test.ReachSmellCase, only: [run_check: 2]
    end
  end

  @doc "Runs `check` over `source`, returning its findings."
  @spec run_check(module(), String.t()) :: [map()]
  def run_check(check, source) do
    dir = Path.join(System.tmp_dir!(), "rustq-reach-smells-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "sample.ex")
    File.write!(path, source)

    [path]
    |> Reach.Project.from_sources(source_only: true, plugins: [])
    |> check.run()
  end
end
