defmodule RustQ.Meta.CorpusInventoryTest do
  use ExUnit.Case, async: true

  test "reports the intentional corpus inventory" do
    assert RustQ.Corpus.coverage() == %{
             case_count: 45,
             categories: %{
               "collections" => 1,
               "control" => 3,
               "expr" => 2,
               "macros" => 4,
               "mutation" => 2,
               "patterns" => 1,
               "propagation" => 31,
               "types" => 1
             },
             unsupported_diagnostics: [
               :unsupported_alias_path,
               :unsupported_binding_pattern,
               :unsupported_cond,
               :unsupported_expression,
               :unsupported_for_reduce,
               :unsupported_function_capture,
               :unsupported_macro_call_fragment,
               :unsupported_match_pattern,
               :unsupported_pipeline_step,
               :unsupported_quote_tokens,
               :unsupported_remote_macro_receiver,
               :unsupported_token_macro_path
             ]
           }
  end
end

defmodule RustQ.Meta.CorpusGoldenTest do
  use ExUnit.Case,
    async: false,
    parameterize:
      Enum.map(RustQ.Corpus.cases(), fn source_path ->
        %{source_path: source_path}
      end)

  @moduletag :corpus

  test "generated Rust matches its golden file", %{source_path: source_path} do
    expected_path = RustQ.Corpus.expected_path(source_path)

    assert File.regular?(expected_path),
           "missing corpus output for #{Path.relative_to_cwd(source_path)}"

    assert RustQ.Corpus.render_file!(source_path) == File.read!(expected_path)
  end
end
