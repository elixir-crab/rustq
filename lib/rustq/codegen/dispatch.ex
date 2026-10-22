defmodule RustQ.Codegen.Dispatch do
  @moduledoc """
  Builds the Rust functions that dispatch a RustQ AST term to the decoder for its node,
  one per category, from `RustQ.Rust.AST.Schema`.
  """

  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.Schema
  alias RustQ.Rust.Identifier

  import RustQ.Rust.AST.ItemBuilder

  require A
  require RustQ.Rust.AST.ItemBuilder

  def asts do
    [
      decode_ast_item_item(),
      decode_ast_type_item(),
      decode_ast_pat_item(),
      decode_ast_stmt_item(),
      decode_ast_expr_item()
    ]
  end

  defp decode_ast_item_item do
    function :decode_ast_item,
      vis: :crate,
      args: [term: "Term"],
      returns: "NifResult<Item>" do
      A.return do
        A.match A.method(A.try(A.call(:struct_name, [:term])), :as_str) do
          decode_ast_item_arms()
        end
      end
    end
  end

  defp decode_ast_item_arms do
    Schema.nodes(:item)
    |> Enum.map(&decode_ast_item_arm/1)
    |> Kernel.++([A.badarg_arm()])
  end

  defp decode_ast_item_arm(%Schema.Node{name: :macro_item, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call([:decode_ast_macro_item], [:term]))
    end
  end

  defp decode_ast_item_arm(%Schema.Node{name: :macro_item_call, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call([:decode_ast_macro_item_call], [:term]))
    end
  end

  defp decode_ast_item_arm(%Schema.Node{name: :macro_rules, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call([:decode_ast_macro_rules], [:term]))
    end
  end

  defp decode_ast_item_arm(%Schema.Node{name: name, rust_const: rust_const}) do
    {wrapper, decoder} = item_decoder(name)

    A.arm P.path([:ast_modules, rust_const]) do
      A.return(
        A.ok(
          A.path_call([:Item, wrapper], [
            A.try(A.path_call(item_decoder_path(name, decoder), [:term]))
          ])
        )
      )
    end
  end

  defp item_decoder_path(_name, decoder), do: [decoder]

  defp item_decoder(:use), do: {:Use, :decode_ast_use}
  defp item_decoder(:module), do: {:Mod, :decode_ast_module}
  defp item_decoder(:const), do: {:Const, :decode_ast_const}
  defp item_decoder(:static), do: {:Static, :decode_ast_static}
  defp item_decoder(:type_alias), do: {:Type, :decode_ast_type_alias}
  defp item_decoder(:impl), do: {:Impl, :decode_ast_impl}
  defp item_decoder(:function), do: {:Fn, :decode_ast_function}
  defp item_decoder(:struct), do: {:Struct, :decode_ast_struct}
  defp item_decoder(:enum), do: {:Enum, :decode_ast_enum}

  defp decode_ast_type_item do
    function :decode_ast_type,
      vis: :crate,
      args: [term: "Term"],
      returns: "NifResult<Type>" do
      A.return do
        A.match A.method(A.try(A.call(:struct_name, [:term])), :as_str) do
          decode_ast_type_arms()
        end
      end
    end
  end

  defp decode_ast_type_arms do
    Schema.nodes(:type)
    |> Enum.map(&decode_ast_type_arm/1)
    |> Kernel.++([A.badarg_arm()])
  end

  defp decode_ast_type_arm(%Schema.Node{name: name, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call(type_decoder_path(name), [:term]))
    end
  end

  defp type_decoder_path(name)
       when name in [
              :type_path,
              :type_ref,
              :type_unit,
              :type_option,
              :type_result,
              :type_nif_result,
              :type_vec,
              :type_slice,
              :type_array,
              :type_bare_fn,
              :type_impl_trait,
              :type_tuple,
              :type_raw
            ],
       do: [type_decoder(name)]

  defp type_decoder_path(name), do: [:super, type_decoder(name)]

  defp type_decoder(name), do: Identifier.atom!("decode_#{name}")

  defp decode_ast_pat_item do
    function :decode_ast_pat,
      vis: :crate,
      args: [term: "Term"],
      returns: "NifResult<Pat>" do
      A.return do
        A.match A.method(A.try(A.call(:struct_name, [:term])), :as_str) do
          decode_ast_pat_arms()
        end
      end
    end
  end

  defp decode_ast_pat_arms do
    Schema.nodes(:pat)
    |> Enum.map(&decode_ast_pat_arm/1)
    |> Kernel.++([A.badarg_arm()])
  end

  defp decode_ast_pat_arm(%Schema.Node{name: name, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call(pat_decoder_path(name), [:term]))
    end
  end

  defp pat_decoder_path(:pat_atom_guard), do: [:super, :decode_pat_atom_guard]

  defp pat_decoder_path(name)
       when name in [
              :pat_var,
              :pat_wildcard,
              :pat_path,
              :pat_literal,
              :pat_none,
              :pat_some,
              :pat_tuple,
              :pat_ok,
              :pat_err,
              :pat_path_tuple,
              :pat_struct,
              :pat_slice
            ],
       do: [pat_decoder(name)]

  defp pat_decoder_path(name),
    do: raise(ArgumentError, "missing pattern decoder for #{inspect(name)}")

  defp pat_decoder(name), do: Identifier.atom!("decode_#{name}")

  defp decode_ast_stmt_item do
    function :decode_ast_stmt,
      vis: :crate,
      args: [term: "Term"],
      returns: "NifResult<Stmt>" do
      A.return do
        A.match A.method(A.try(A.call(:struct_name, [:term])), :as_str) do
          decode_ast_stmt_arms()
        end
      end
    end
  end

  defp decode_ast_stmt_arms do
    Schema.nodes(:stmt)
    |> Enum.map(&decode_ast_stmt_arm/1)
    |> Kernel.++([A.badarg_arm()])
  end

  defp decode_ast_stmt_arm(%Schema.Node{name: name, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call(stmt_decoder_path(name), [:term]))
    end
  end

  defp stmt_decoder_path(:let), do: [:decode_stmt_let]
  defp stmt_decoder_path(:let_else), do: [:decode_stmt_let_else]
  defp stmt_decoder_path(:assign), do: [:decode_stmt_assign]
  defp stmt_decoder_path(:assign_op), do: [:decode_stmt_assign_op]
  defp stmt_decoder_path(:expr_stmt), do: [:decode_stmt_expr_stmt]
  defp stmt_decoder_path(:return), do: [:decode_stmt_return]
  defp stmt_decoder_path(:early_return), do: [:decode_stmt_early_return]
  defp stmt_decoder_path(:if_let), do: [:decode_stmt_if_let]
  defp stmt_decoder_path(:for), do: [:decode_stmt_for]
  defp stmt_decoder_path(:loop), do: [:decode_stmt_loop]
  defp stmt_decoder_path(:break), do: [:decode_stmt_break]
  defp stmt_decoder_path(:continue), do: [:decode_stmt_continue]

  defp decode_ast_expr_item do
    function :decode_ast_expr,
      vis: :crate,
      args: [term: "Term"],
      returns: "NifResult<Expr>" do
      A.return do
        A.match A.method(A.try(A.call(:struct_name, [:term])), :as_str) do
          decode_ast_expr_arms()
        end
      end
    end
  end

  defp decode_ast_expr_arms do
    Schema.nodes(:expr)
    |> Enum.map(&decode_ast_expr_arm/1)
    |> Kernel.++([A.badarg_arm()])
  end

  defp decode_ast_expr_arm(%Schema.Node{name: name, rust_const: rust_const}) do
    A.arm P.path([:ast_modules, rust_const]) do
      A.return(A.path_call(expr_decoder_path(name), [:term]))
    end
  end

  defp expr_decoder_path(name)
       when name in [
              :var,
              :path,
              :field,
              :index,
              :range,
              :cast,
              :unary_op,
              :path_call,
              :method_call,
              :local_call,
              :struct_literal,
              :ref,
              :try,
              :tuple,
              :vec_literal,
              :array_literal,
              :macro_repeat_expr,
              :closure,
              :literal,
              :byte_string,
              :escape_expr,
              :token_macro,
              :macro_call,
              :atom_value,
              :none,
              :some,
              :ok,
              :err,
              :nif_raise_atom,
              :block_expr,
              :unsafe_block,
              :match,
              :if,
              :binary_op
            ],
       do: [expr_decoder(name)]

  defp expr_decoder_path(name),
    do: raise(ArgumentError, "missing expression decoder for #{inspect(name)}")

  defp expr_decoder(name), do: Identifier.atom!("decode_expr_#{name}")
end
