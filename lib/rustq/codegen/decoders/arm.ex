defmodule RustQ.Codegen.Decoders.Arm do
  @moduledoc false

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.DecoderHelpers, RustQ.Codegen.Helpers]

  @spec decode_arm(term()) :: R.nif_result(R.path(:Arm))
  defrust decode_arm(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Arm")
    pat_term = required_field(term, "pattern")
    guard = Super.decode_optional_expr_field(term, "guard")
    block = Super.decode_block(required_field(term, "body"))

    arm =
      if struct_name(pat_term) == "Elixir.RustQ.Rust.AST.PatAtomGuard" do
        Super.decode_atom_guard_arm(pat_term, block)
      else
        Super.parse_guarded_block_arm(Super.decode_pat(pat_term), guard, block)
      end

    Super.arm_with_attrs(arm, Super.decode_attribute_list(required_field(term, "attrs")))
  end
end
