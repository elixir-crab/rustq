defmodule RustQ.Codegen.Decoders.Pat do
  @moduledoc """
  Rusty-Elixir decoders from RustQ AST terms to `syn` patterns, compiled into
  `generated_ast.rs` for the native renderer.
  """

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.DecoderHelpers, RustQ.Codegen.Helpers]

  @spec decode_pat_var(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_var(term) do
    ident = Super.format_ident_value(atom_key(term, "name"))
    mutable = required_field(term, "mutable").decode()

    Super.parse_var_pat(ident, mutable)
  end

  @spec decode_pat_wildcard(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_wildcard(term) do
    Super.parse_wildcard_pat(term)
  end

  @spec decode_pat_none(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_none(term) do
    Super.parse_none_pat(term)
  end

  @spec decode_pat_path(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_path(term) do
    Super.parse_path_pat(required_path(term, "path"))
  end

  @spec decode_pat_literal(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_literal(term) do
    Super.decode_pat_literal_value(required_field(term, "value"))
  end

  @spec decode_pat_some(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_some(term) do
    Super.parse_some_pat(required_pat(term, "pattern"))
  end

  @spec decode_pat_ok(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_ok(term) do
    Super.parse_ok_pat(required_pat(term, "pattern"))
  end

  @spec decode_pat_err(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_err(term) do
    Super.parse_err_pat(required_pat(term, "pattern"))
  end

  @spec decode_pat_tuple(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_tuple(term) do
    Super.parse_tuple_pat(required_pat_list(term, "patterns"))
  end

  @spec decode_pat_path_tuple(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_path_tuple(term) do
    Super.parse_path_tuple_pat(required_path(term, "path"), required_pat_list(term, "patterns"))
  end

  @spec decode_pat_slice(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_slice(term) do
    Super.parse_slice_pat(
      required_pat_list(term, "patterns"),
      Super.decode_optional_pat_field(term, "rest")
    )
  end

  @spec decode_pat_struct(term()) :: R.nif_result(R.path(:Pat))
  defrust decode_pat_struct(term) do
    Super.parse_struct_pat(
      required_path(term, "path"),
      Super.decode_pat_struct_fields(required_field(term, "fields"))
    )
  end
end
