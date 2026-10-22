defmodule Mix.Tasks.Rustq.Gen do
  @moduledoc """
  Generates files declared in `rustq.exs`.

      mix rustq.gen
      mix rustq.gen --check
      mix rustq.gen term_helpers
      mix rustq.gen --config path/to/rustq.exs

  Use `--check` in CI to verify that generated files are up to date without
  writing them. Passing one or more target names generates only those targets.
  """

  use Mix.Task

  @shortdoc "Generates files declared in rustq.exs"

  @impl Mix.Task
  def run(args) do
    {opts, names, invalid} =
      OptionParser.parse(args, strict: [check: :boolean, config: :string])

    if invalid != [] do
      Mix.raise("invalid rustq.gen options: #{inspect(invalid)}")
    end

    config = Keyword.get(opts, :config, "rustq.exs")

    config
    |> RustQ.Generated.load_manifest!()
    |> RustQ.Generated.sync_all!(
      check: Keyword.get(opts, :check, false),
      only: names,
      shell: Mix.shell()
    )
  rescue
    error in RustQ.Generated.StaleError -> Mix.raise(Exception.message(error))
  end
end
