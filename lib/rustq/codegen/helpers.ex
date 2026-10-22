defmodule RustQ.Codegen.Helpers do
  @moduledoc """
  Rusty-Elixir helpers for reading fields and values out of RustQ AST terms, which the
  generated decoders call. Compiled to Rust in `generated_ast.rs`.
  """

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.ModuleHelpers]

  @spec required_field(term(), R.str()) :: R.nif_result(term())
  defrust required_field(term, key) do
    term.map_get(atom(term.get_env(), key))
  end

  @spec optional_map_get(term(), R.str()) :: R.nif_result(R.option(term()))
  defrust optional_map_get(term, key) do
    case term.map_get(unwrap!(atom(term.get_env(), key))) do
      {:ok, value} -> {:ok, some(value)}
      {:error, _reason} -> {:ok, nil}
    end
  end

  @spec atom_key(term(), R.str()) :: R.nif_result(String.t())
  defrust atom_key(term, key) do
    term.map_get(atom(term.get_env(), key)).atom_to_string()
  end

  @spec optional_atom_key(term(), R.str()) :: R.nif_result(R.option(String.t()))
  defrust optional_atom_key(term, key) do
    value = unwrap!(term.map_get(unwrap!(atom(term.get_env(), key))))

    if unwrap!(is_nil(value)) do
      {:ok, nil}
    else
      {:ok, some(unwrap!(value.atom_to_string()))}
    end
  end

  @spec is_nil(term()) :: R.nif_result(boolean())
  defrust is_nil(term) do
    {:ok, term.is_atom() and unwrap!(term.atom_to_string()) == "nil"}
  end

  @spec struct_name(term()) :: R.nif_result(String.t())
  defrust struct_name(term) do
    term.map_get(atom(term.get_env(), "__struct__")).atom_to_string()
  end

  @spec expect_struct(term(), R.str()) :: R.nif_result(R.unit())
  defrust expect_struct(term, expected) do
    if unwrap!(struct_name(term)) == expected do
      :ok
    else
      {:error, badarg()}
    end
  end
end
