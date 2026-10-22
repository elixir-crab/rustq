defmodule Mix.Tasks.Rustq.Std do
  @moduledoc """
  Derives RustQ's facts about Rust standard library methods from std's source.

      mix rustq.std
      mix rustq.std --check

  Which collection methods take `&mut self`, which methods return iterators or options, and
  which belong to `Option` and `Result` are read from the source rustup installs with
  `rustup component add rust-src`, and written to `lib/rustq/meta/std_methods.ex`.

  `--check` verifies the committed file against the source of the Rust release it was
  generated from, which must be the active toolchain.
  """

  use Mix.Task

  alias RustQ.Meta.StdMethods
  alias RustQ.Meta.StdMethods.Source

  @shortdoc "Derives facts about Rust std methods from std's source"

  @impl Mix.Task
  def run(args) do
    {opts, _args, invalid} = OptionParser.parse(args, strict: [check: :boolean])

    if invalid != [] do
      Mix.raise("invalid rustq.std options: #{inspect(invalid)}")
    end

    Mix.Task.run("compile")

    check = Keyword.get(opts, :check, false)
    version = Source.rust_version!()

    if check and version != StdMethods.rust_version() do
      Mix.raise(
        "#{Source.path()} was generated from Rust #{StdMethods.rust_version()}, " <>
          "but the active toolchain is #{version}; check with " <>
          "RUSTUP_TOOLCHAIN=#{StdMethods.rust_version()}, or regenerate"
      )
    end

    RustQ.Generated.sync!(
      :std_methods,
      [path: Source.path(), build: fn -> Source.build!(Source.library!(), version) end],
      check: check,
      command: "mix rustq.std",
      shell: Mix.shell()
    )
  rescue
    error in RustQ.Generated.StaleError -> Mix.raise(Exception.message(error))
  end
end
