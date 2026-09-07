defmodule RustQ.Codegen.Decoders.Expr do
  @moduledoc false

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.DecoderHelpers, RustQ.Codegen.Helpers]

  @spec decode_expr_var(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_var(term) do
    ident = Super.format_ident_value(atom_key(term, "name"))
    Super.parse_ident_expr(ident)
  end

  @spec decode_expr_path(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_path(term) do
    Super.parse_path_expr(Super.parse_ast_path(term))
  end

  @spec decode_expr_atom_value(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_atom_value(term) do
    name = Super.format_ident_value(atom_key(term, "name"))
    Super.parse_atom_value_expr(Super.decode_string_list(required_field(term, "module")), name)
  end

  @spec decode_expr_field(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_field(term) do
    Super.parse_field_expr(required_expr(term, "receiver"), required_field(term, "field"))
  end

  @spec decode_expr_index(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_index(term) do
    Super.parse_index_expr(required_expr(term, "receiver"), required_expr(term, "index"))
  end

  @spec decode_expr_range(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_range(term) do
    Super.parse_range_expr(
      Super.decode_optional_expr_field(term, "start"),
      Super.decode_optional_expr_field(term, "stop"),
      decode_as!(required_field(term, "inclusive"), boolean())
    )
  end

  @spec decode_expr_cast(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_cast(term) do
    Super.parse_cast_expr(required_expr(term, "expr"), required_type(term, "type"))
  end

  @spec decode_expr_unary_op(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_unary_op(term) do
    op = unwrap!(atom_key(term, "op"))
    expr = required_expr(term, "expr")

    case op.as_str() do
      "not" -> Super.parse_unary_expr(op, expr)
      "neg" -> Super.parse_unary_expr(op, expr)
      "deref" -> Super.parse_unary_expr(op, expr)
      _ -> err(badarg())
    end
  end

  @spec decode_expr_path_call(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_path_call(term) do
    Super.parse_path_call_expr(
      required_path(term, "path"),
      required_expr_list(term, "args"),
      required_type_list(term, "generics")
    )
  end

  @spec decode_expr_method_call(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_method_call(term) do
    method = Super.format_ident_value(atom_key(term, "method"))

    Super.parse_method_call_expr(
      required_expr(term, "receiver"),
      method,
      required_expr_list(term, "args"),
      required_type_list(term, "generics")
    )
  end

  @spec decode_expr_local_call(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_local_call(term) do
    Super.parse_local_call(atom_key(term, "name"), required_expr_list(term, "args"))
  end

  @spec decode_expr_ref(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_ref(term) do
    Super.parse_ref_expr(required_expr(term, "expr"), required_field(term, "mutable").decode())
  end

  @spec decode_expr_struct_literal(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_struct_literal(term) do
    Super.parse_struct_literal_expr(
      required_expr(term, "path"),
      Super.decode_struct_literal_fields(required_field(term, "fields"))
    )
  end

  @spec decode_expr_nif_raise_atom(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_nif_raise_atom(term) do
    Super.parse_raise_atom_expr(atom_key(term, "name"))
  end

  @spec decode_expr_binary_op(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_binary_op(term) do
    Super.parse_binary_expr(
      required_expr(term, "left"),
      atom_key(term, "op"),
      required_expr(term, "right")
    )
  end

  @spec decode_expr_block_expr(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_block_expr(term) do
    Super.parse_block_expr(Super.decode_block(required_field(term, "body")))
  end

  @spec decode_expr_unsafe_block(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_unsafe_block(term) do
    Super.parse_unsafe_block_expr(Super.decode_block(required_field(term, "body")))
  end

  @spec decode_expr_match(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_match(term) do
    Super.parse_match_expr(required_expr(term, "expr"), required_arm_list(term, "arms"))
  end

  @spec decode_expr_if(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_if(term) do
    Super.parse_if_expr(
      required_expr(term, "condition"),
      Super.decode_block(required_field(term, "then")),
      Super.decode_optional_block_field(term, "else")
    )
  end

  @spec decode_expr_tuple(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_tuple(term) do
    Super.parse_tuple_expr(required_expr_list(term, "values"))
  end

  @spec decode_expr_vec_literal(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_vec_literal(term) do
    Super.parse_vec_expr(required_expr_list(term, "values"))
  end

  @spec decode_expr_array_literal(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_array_literal(term) do
    Super.parse_array_expr(required_expr_list(term, "values"))
  end

  @spec decode_expr_macro_repeat_expr(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_macro_repeat_expr(term) do
    Super.parse_macro_repeat_expr(
      required_expr(term, "expr"),
      Super.string_field(term, "separator"),
      Super.string_field(term, "operator")
    )
  end

  @spec decode_expr_closure(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_closure(term) do
    Super.parse_pattern_closure_expr(
      Super.decode_closure_args(required_field(term, "args")),
      required_expr(term, "body"),
      decode_as!(required_field(term, "move"), R.bool())
    )
  end

  @spec decode_expr_macro_call(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_macro_call(term) do
    Super.parse_macro_call_expr(required_path(term, "path"), required_expr_list(term, "args"))
  end

  @spec decode_expr_byte_string(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_byte_string(term) do
    Super.parse_byte_string_expr(Super.string_field(term, "value"))
  end

  @spec decode_expr_escape_expr(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_escape_expr(term) do
    Super.parse_expr(Super.string_field(term, "source"))
  end

  @spec decode_expr_token_macro(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_token_macro(term) do
    path =
      unwrap!(
        Super.path_parts(unwrap!(required_field(unwrap!(required_field(term, "path")), "parts")))
      )

    tokens = unwrap!(Super.string_field(term, "tokens"))
    Super.parse_expr(token_macro(:format, "\"{}!({})\", path, tokens"))
  end

  @spec decode_expr_ok(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_ok(term) do
    Super.parse_ok_expr(Super.decode_optional_expr_field(term, "expr"))
  end

  @spec decode_expr_none(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_none(term) do
    Super.parse_none_expr(term)
  end

  @spec decode_expr_literal(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_literal(term) do
    Super.decode_literal_expr(required_field(term, "value"))
  end

  @spec decode_expr_try(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_try(term) do
    Super.parse_try_expr(required_expr(term, "expr"))
  end

  @spec decode_expr_some(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_some(term) do
    Super.parse_some_expr(required_expr(term, "expr"))
  end

  @spec decode_expr_err(term()) :: R.nif_result(R.path(:Expr))
  defrust decode_expr_err(term) do
    Super.parse_err_expr(required_expr(term, "expr"))
  end
end
