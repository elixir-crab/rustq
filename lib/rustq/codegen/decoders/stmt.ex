defmodule RustQ.Codegen.Decoders.Stmt do
  @moduledoc """
  Rusty-Elixir decoders from RustQ AST terms to `syn` statements, compiled into
  `generated_ast.rs` for the native renderer.
  """

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.DecoderHelpers, RustQ.Codegen.Helpers]

  @spec decode_stmt_assign(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_assign(term) do
    Super.parse_assign_stmt(required_expr(term, "target"), required_expr(term, "expr"))
  end

  @spec decode_stmt_assign_op(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_assign_op(term) do
    op = unwrap!(unwrap!(required_field(term, "op")).atom_to_string())

    Super.parse_assign_op_stmt(
      required_expr(term, "target"),
      op.as_str(),
      required_expr(term, "expr")
    )
  end

  @spec decode_stmt_expr_stmt(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_expr_stmt(term) do
    Super.parse_expr_stmt(required_expr(term, "expr"))
  end

  @spec decode_stmt_return(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_return(term) do
    {:ok, Stmt.expr(unwrap!(required_expr(term, "expr")), none())}
  end

  @spec decode_stmt_early_return(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_early_return(term) do
    Super.parse_return_stmt(required_expr(term, "expr"))
  end

  @spec decode_stmt_if_let(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_if_let(term) do
    Super.parse_if_let_stmt(
      required_pat(term, "pattern"),
      required_expr(term, "expr"),
      Super.decode_block(required_field(term, "then")),
      Super.decode_optional_block_field(term, "else")
    )
  end

  @spec decode_stmt_for(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_for(term) do
    Super.parse_for_stmt(
      required_pat(term, "pattern"),
      required_expr(term, "expr"),
      Super.decode_block(required_field(term, "body"))
    )
  end

  @spec decode_stmt_loop(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_loop(term) do
    Super.parse_loop_stmt(Super.decode_block(required_field(term, "body")))
  end

  @spec decode_stmt_break(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_break(term) do
    Super.parse_break_stmt(Super.decode_optional_expr_field(term, "expr"))
  end

  @spec decode_stmt_continue(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_continue(_term) do
    Super.parse_continue_stmt()
  end

  @spec decode_stmt_let(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_let(term) do
    pattern = required_pat(term, "pattern")
    mutable = required_field(term, "mutable").decode()
    pat_tokens = Super.decode_let_pattern(pattern, mutable)

    Super.parse_let_stmt(
      pat_tokens,
      Super.decode_optional_type_field(term, "type"),
      required_expr(term, "expr")
    )
  end

  @spec decode_stmt_let_else(term()) :: R.nif_result(R.path(:Stmt))
  defrust decode_stmt_let_else(term) do
    Super.parse_let_else_stmt(
      required_pat(term, "pattern"),
      required_expr(term, "expr"),
      Super.decode_block(required_field(term, "else"))
    )
  end
end
