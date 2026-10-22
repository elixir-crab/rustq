defmodule Mix.Tasks.Rustq.Corpus do
  @moduledoc """
  Checks or updates the RustQ golden lowering corpus.

      mix rustq.corpus
      mix rustq.corpus --update
      mix rustq.corpus --coverage
  """

  use Mix.Task

  @shortdoc "Checks or updates the RustQ golden lowering corpus"

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [update: :boolean, coverage: :boolean])

    cond do
      opts[:update] ->
        updated = RustQ.Corpus.update!()
        Mix.shell().info("Updated #{length(updated)} corpus expectations")

      opts[:coverage] ->
        report_coverage(RustQ.Corpus.coverage())

      true ->
        check_stale!()
    end
  end

  defp check_stale! do
    case RustQ.Corpus.stale_cases() do
      [] ->
        Mix.shell().info("Corpus is up to date")

      stale ->
        Enum.each(stale, fn {source_path, _expected, _actual} ->
          Mix.shell().error("stale corpus expectation: #{Path.relative_to_cwd(source_path)}")
        end)

        Mix.raise(
          "#{length(stale)} corpus expectation(s) are stale; run mix rustq.corpus --update"
        )
    end
  end

  defp report_coverage(%{
         case_count: case_count,
         categories: categories,
         unsupported_diagnostics: codes
       }) do
    Mix.shell().info("Corpus cases: #{case_count}")
    Mix.shell().info("Corpus categories:")

    categories
    |> Enum.sort()
    |> Enum.each(fn {category, count} -> Mix.shell().info("  #{category}: #{count}") end)

    Mix.shell().info("Unsupported lowerer diagnostics: #{length(codes)}")
    Enum.each(codes, &Mix.shell().info("  #{&1}"))
  end
end
