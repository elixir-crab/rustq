defmodule RustQ.Codegen.Decoders.Item do
  @moduledoc false

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.DecoderHelpers, RustQ.Codegen.Helpers]

  @spec decode_ast_use(term()) :: R.nif_result(R.path(:ItemUse))
  defrust decode_ast_use(term) do
    unwrap!(expect_struct(term, "Elixir.RustQ.Rust.AST.Use"))
    parts = unwrap!(required_field(term, "parts"))

    if is_nil(parts) do
      group = unwrap!(required_field(term, "group"))

      if is_nil(group) do
        tree = unwrap!(Super.string_field(term, "tree"))
        Super.parse_item_use(tree)
      else
        Super.parse_item_use_group_term(group)
      end
    else
      parts = unwrap!(Super.decode_string_list(parts))
      Super.parse_item_use_path(parts)
    end
  end

  @spec decode_ast_module(term()) :: R.nif_result(R.path(:ItemMod))
  defrust decode_ast_module(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Module")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_module(
      name,
      Super.decode_vis(required_field(term, "vis")),
      required_item_list(term, "items")
    )
  end

  @spec decode_ast_impl(term()) :: R.nif_result(R.path(:ItemImpl))
  defrust decode_ast_impl(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Impl")

    Super.parse_item_impl(
      required_type(term, "target"),
      Super.decode_optional_type_field(term, "trait"),
      required_item_list(term, "items"),
      Super.decode_attribute_list(required_field(term, "attrs")),
      unwrap!(decode_lifetime_list(unwrap!(required_field(term, "lifetimes"))))
    )
  end

  @spec decode_ast_const(term()) :: R.nif_result(R.path(:ItemConst))
  defrust decode_ast_const(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Const")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_const(
      name,
      required_type(term, "type"),
      required_expr(term, "expr"),
      Super.decode_vis(required_field(term, "vis"))
    )
  end

  @spec decode_ast_type_alias(term()) :: R.nif_result(R.path(:ItemType))
  defrust decode_ast_type_alias(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.TypeAlias")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_type(
      name,
      required_type(term, "type"),
      Super.decode_vis(required_field(term, "vis"))
    )
  end

  @spec decode_ast_static(term()) :: R.nif_result(R.path(:ItemStatic))
  defrust decode_ast_static(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Static")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_static(
      name,
      required_type(term, "type"),
      required_expr(term, "expr"),
      required_field(term, "mutable").decode(),
      Super.decode_vis(required_field(term, "vis"))
    )
  end

  @spec decode_ast_function(term()) :: R.nif_result(R.path(:ItemFn))
  defrust decode_ast_function(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Function")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_function_args(
      name,
      Super.decode_vis(required_field(term, "vis")),
      required_function_arg_list(term, "args"),
      required_type(term, "returns"),
      unwrap!(decode_lifetime_list(unwrap!(required_field(term, "lifetimes")))),
      required_stmt_list(term, "body"),
      Super.decode_attribute_list(required_field(term, "attrs"))
    )
  end

  @spec decode_derive_path_list(term()) :: R.nif_result(R.vec(Path.t()))
  defrust decode_derive_path_list(term) do
    terms = unwrap!(Super.decode_derive_path_terms(term))

    Enum.map(terms, fn derive_path ->
      Super.decode_path_value(derive_path)
    end)
  end

  @spec decode_ast_struct(term()) :: R.nif_result(R.path(:ItemStruct))
  defrust decode_ast_struct(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Struct")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_struct(
      name,
      Super.decode_vis(required_field(term, "vis")),
      Super.decode_derive(required_field(term, "derive")),
      unwrap!(decode_lifetime_list(unwrap!(required_field(term, "lifetimes")))),
      required_struct_field_list(term, "fields"),
      Super.decode_attribute_list(required_field(term, "attrs"))
    )
  end

  @spec decode_ast_macro_item(term()) :: R.nif_result(R.path(:Item))
  defrust decode_ast_macro_item(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.MacroItem")
    Super.parse_macro_item(Super.string_field(term, "source"))
  end

  @spec decode_ast_macro_item_call(term()) :: R.nif_result(R.path(:Item))
  defrust decode_ast_macro_item_call(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.MacroItemCall")
    path = required_path(term, "path")
    tokens = unwrap!(required_field(term, "tokens"))

    if is_nil(tokens) do
      Super.parse_macro_item_call(
        path,
        Super.decode_macro_item_arg_list(required_field(term, "args"))
      )
    else
      Super.parse_macro_item_token_call(path, tokens)
    end
  end

  @spec decode_ast_macro_rules(term()) :: R.nif_result(R.path(:Item))
  defrust decode_ast_macro_rules(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.MacroRules")
    Super.parse_macro_rules_term(term)
  end

  @spec decode_ast_enum(term()) :: R.nif_result(R.path(:ItemEnum))
  defrust decode_ast_enum(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.Enum")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_item_enum(
      name,
      Super.decode_vis(required_field(term, "vis")),
      Super.decode_derive(required_field(term, "derive")),
      unwrap!(required_enum_variant_list(term, "variants")),
      Super.decode_attribute_list(required_field(term, "attrs"))
    )
  end

  @spec decode_function_arg(term()) :: R.nif_result(R.path(:FnArg))
  defrust decode_function_arg(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.FunctionArg")
    receiver = unwrap!(decode_as(unwrap!(required_field(term, "receiver")), R.bool()))
    mutable = unwrap!(decode_as(unwrap!(required_field(term, "mutable")), R.bool()))

    if receiver do
      Super.parse_function_receiver(mutable)
    else
      Super.parse_function_arg(
        Super.format_ident_value(atom_key(term, "name")),
        required_type(term, "type"),
        mutable
      )
    end
  end

  @spec decode_struct_field(term()) :: R.nif_result(R.path(:Field))
  defrust decode_struct_field(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.StructField")
    name = Super.format_ident_value(atom_key(term, "name"))

    Super.parse_struct_field(
      name,
      required_type(term, "type"),
      Super.decode_vis(required_field(term, "vis"))
    )
  end

  @spec decode_enum_variant(term()) :: R.nif_result(R.path(:Variant))
  defrust decode_enum_variant(term) do
    expect_struct(term, "Elixir.RustQ.Rust.AST.EnumVariant")

    Super.parse_enum_variant(
      Super.format_ident_value(atom_key(term, "name")),
      required_type_list(term, "tuple")
    )
  end
end
