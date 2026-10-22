defmodule RustQ.Codegen.ModuleHelpers do
  @moduledoc """
  Rusty-Elixir helpers for the generated AST modules, such as `atom/2`, which makes the
  atom naming a RustQ AST node module. Compiled to Rust in `generated_ast.rs`.
  """

  use RustQ.Codegen.DefrustModule

  @spec atom(R.path(:Env), R.str()) :: R.nif_result(R.path(:Atom))
  defrust atom(env, name) do
    Atom.from_str(env, name)
  end
end
