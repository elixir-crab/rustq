defmodule RustQ.Meta.Lower.CallPropagationTest do
  use ExUnit.Case, async: true

  alias RustQ.Binding.Callable
  alias RustQ.Meta.GeneratedCase, as: Generated
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Lower.Paths
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  import RustQ.Meta.LowerCase

  test "infers local call argument propagation from callable arg types" do
    path_type = %Type{kind: :type, rust: "Path", ast: %AST.TypePath{parts: [:Path]}}

    option_path = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeOption{inner: path_type.ast},
      meta: %{inner: path_type}
    }

    statements =
      Lower.quoted_body(
        quote do
          draw_path(maybe_path())
          :ok
        end,
        unit_type(),
        %{},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path},
          %Callable{
            name: "draw_path",
            kind: :function,
            args: [%{name: "path", type: path_type, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.LocalCall{
                 name: :draw_path,
                 args: [%AST.Try{expr: %AST.LocalCall{name: :maybe_path}}]
               }
             },
             %AST.Return{}
           ] = statements
  end

  test "auto-borrows option some inners for impl Into option arguments" do
    rect_type = %Type{kind: :type, rust: "Rect", ast: %AST.TypePath{parts: [:Rect]}}

    constraint_type = %Type{
      kind: :type,
      rust: "Constraint",
      ast: %AST.TypePath{parts: [:Constraint]}
    }

    ref_rect_type = %Type{
      kind: :ref,
      rust: "&Rect",
      ast: %AST.TypeRef{inner: rect_type.ast},
      meta: %{inner: rect_type}
    }

    tuple_type = %Type{
      kind: :tuple,
      rust: "(&Rect, Constraint)",
      ast: %AST.TypeRaw{source: "(&Rect, Constraint)"},
      meta: %{elements: [ref_rect_type, constraint_type]}
    }

    option_tuple = %Type{
      kind: :option,
      rust: "Option<(&Rect, Constraint)>",
      ast: %AST.TypeOption{inner: tuple_type.ast},
      meta: %{inner: tuple_type}
    }

    into_option_tuple = %Type{
      kind: :impl_trait,
      rust: "impl Into<Option<(&Rect, Constraint)>>",
      ast: %AST.TypeRaw{source: "impl Into<Option<(&Rect, Constraint)>>"},
      meta: %{traits: [%Type{meta: %{syn_name: "Into", args: [option_tuple]}}]}
    }

    statements =
      Lower.quoted_body(
        quote do
          draw_option(some({rect, constraint}))
          draw_option(src)
          :ok
        end,
        unit_type(),
        %{rect: rect_type, constraint: constraint_type, src: option_tuple},
        callables: [
          %Callable{
            name: "draw_option",
            kind: :function,
            args: [%{name: "source", type: into_option_tuple, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.LocalCall{
                 name: :draw_option,
                 args: [
                   %AST.Some{
                     expr: %AST.Tuple{
                       values: [
                         %AST.Ref{expr: %AST.Var{name: :rect}},
                         %AST.Var{name: :constraint}
                       ]
                     }
                   }
                 ]
               }
             },
             %AST.ExprStmt{
               expr: %AST.LocalCall{name: :draw_option, args: [%AST.Var{name: :src}]}
             },
             %AST.Return{}
           ] = statements
  end

  test "does not propagate option call arguments in nif result context" do
    path_type = %Type{kind: :type, rust: "Path", ast: %AST.TypePath{parts: [:Path]}}

    option_path = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeOption{inner: path_type.ast},
      meta: %{inner: path_type}
    }

    nif_unit = %Type{
      kind: :nif_result,
      rust: "NifResult<()>",
      ast: %AST.TypeNifResult{inner: %AST.TypeUnit{}},
      meta: %{inner: unit_type()}
    }

    statements =
      Lower.quoted_body(
        quote do
          draw_path(maybe_path())
          :ok
        end,
        nif_unit,
        %{},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path},
          %Callable{
            name: "draw_path",
            kind: :function,
            args: [%{name: "path", type: path_type, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.LocalCall{
                 name: :draw_path,
                 args: [%AST.LocalCall{name: :maybe_path}]
               }
             },
             %AST.Return{}
           ] = statements
  end

  test "a fallible receiver of a method its result lacks propagates first" do
    nif_count = RustQ.Spec.type(quote(do: RustQ.Type.nif_result(RustQ.Type.u32())))

    statements =
      Lower.quoted_body(
        quote do
          {:ok, read_count().max(1)}
        end,
        nif_count,
        %{},
        callables: [%Callable{name: "read_count", kind: :function, args: [], returns: nif_count}]
      )

    assert RustQ.Rust.render_all(statements) =~ "Ok(read_count()?.max(1))"
  end

  test "infers remote call argument propagation from free-function callable metadata" do
    mode_type = %Type{kind: :type, rust: "Mode", ast: %AST.TypePath{parts: [:Mode]}}

    result_mode = %Type{
      kind: :nif_result,
      rust: "NifResult<Mode>",
      ast: %AST.TypeNifResult{inner: mode_type.ast},
      meta: %{inner: mode_type}
    }

    statements =
      Lower.quoted_body(
        quote do
          paint.set_blend_mode(GeneratedEnums.decode_blend_mode(atom))
          :ok
        end,
        unit_type(),
        %{
          paint: %Type{
            kind: :mut_ref,
            rust: "&mut skia_safe::Paint",
            ast: %AST.TypeRef{inner: %AST.TypePath{parts: [:skia_safe, :Paint]}, mutable: true}
          },
          atom: %Type{kind: :atom, rust: "Atom", ast: %AST.TypePath{parts: [:Atom]}}
        },
        callables: [
          %Callable{
            name: "decode_blend_mode",
            kind: :function,
            args: [
              %{
                name: "atom",
                type: %Type{kind: :atom, rust: "Atom", ast: %AST.TypePath{parts: [:Atom]}},
                syn: nil
              }
            ],
            returns: result_mode
          },
          %Callable{
            name: "set_blend_mode",
            kind: :method,
            target: "Paint",
            args: [self_arg(), %{name: "mode", type: mode_type, syn: nil}],
            returns: nil
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.MethodCall{
                 method: :set_blend_mode,
                 args: [
                   %AST.Try{
                     expr: %AST.PathCall{
                       path: %AST.Path{parts: [:generated_enums, :decode_blend_mode]}
                     }
                   }
                 ]
               }
             },
             %AST.Return{}
           ] = statements
  end

  test "infers remote call argument propagation from callable arg types" do
    path_type = %Type{kind: :type, rust: "Path", ast: %AST.TypePath{parts: [:Path]}}

    result_path = %Type{
      kind: :result,
      rust: "Result<Path, Error>",
      ast: %AST.TypeResult{ok: path_type.ast, error: %AST.TypePath{parts: [:Error]}},
      meta: %{ok: path_type}
    }

    statements =
      Lower.quoted_body(
        quote do
          Generated.draw_path(Generated.decode_path(term))
          :ok
        end,
        unit_type(),
        %{term: %Type{kind: :term, rust: "Term", ast: %AST.TypePath{parts: [:Term]}}},
        callables: [
          %Callable{
            name: "decode_path",
            kind: :function,
            target: "Generated",
            args: [
              %{
                name: "term",
                type: %Type{kind: :term, rust: "Term", ast: %AST.TypePath{parts: [:Term]}},
                syn: nil
              }
            ],
            returns: result_path
          },
          %Callable{
            name: "draw_path",
            kind: :function,
            target: "Generated",
            args: [%{name: "path", type: path_type, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.PathCall{
                 path: %AST.Path{parts: [:Generated, :draw_path]},
                 args: [
                   %AST.Try{
                     expr: %AST.PathCall{path: %AST.Path{parts: [:Generated, :decode_path]}}
                   }
                 ]
               }
             },
             %AST.Return{}
           ] = statements
  end

  test "infers method call argument propagation from typed receiver metadata" do
    path_type = %Type{kind: :type, rust: "Path", ast: %AST.TypePath{parts: [:Path]}}
    canvas_type = %Type{kind: :type, rust: "Canvas", ast: %AST.TypePath{parts: [:Canvas]}}

    option_path = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeOption{inner: path_type.ast},
      meta: %{inner: path_type}
    }

    statements =
      Lower.quoted_body(
        quote do
          canvas.draw_path(maybe_path())
          :ok
        end,
        unit_type(),
        %{canvas: canvas_type},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path},
          %Callable{
            name: "draw_path",
            kind: :method,
            target: "Canvas",
            args: [self_arg(), %{name: "path", type: path_type, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.MethodCall{
                 receiver: %AST.Var{name: :canvas},
                 method: :draw_path,
                 args: [%AST.Try{expr: %AST.LocalCall{name: :maybe_path}}]
               }
             },
             %AST.Return{}
           ] = statements
  end

  test "does not infer argument propagation without callee metadata" do
    path_type = %Type{kind: :type, rust: "Path", ast: %AST.TypePath{parts: [:Path]}}

    option_path = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeOption{inner: path_type.ast},
      meta: %{inner: path_type}
    }

    statements =
      Lower.quoted_body(
        quote do
          draw_path(maybe_path())
          :ok
        end,
        unit_type(),
        %{},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path}
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.LocalCall{name: :draw_path, args: [%AST.LocalCall{name: :maybe_path}]}
             },
             %AST.Return{}
           ] = statements
  end

  test "does not infer propagation when expected type is still the wrapper" do
    path_type = %Type{kind: :type, rust: "Path", ast: %AST.TypePath{parts: [:Path]}}

    option_path = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeOption{inner: path_type.ast},
      meta: %{inner: path_type}
    }

    statements =
      Lower.quoted_body(quote(do: maybe_path()), option_path, %{},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path}
        ]
      )

    assert [%AST.Return{expr: %AST.LocalCall{name: :maybe_path, args: []}}] = statements
  end

  test "looks up callable return types from metadata" do
    return_type = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeRaw{source: "Option<Path>"}
    }

    callables = [
      %Callable{name: "maybe_path", kind: :function, args: [], returns: return_type},
      %Callable{
        name: "draw_rect",
        kind: :method,
        target: "Canvas",
        args: [self_arg(), rect_arg()],
        returns: return_type
      }
    ]

    assert Paths.callable_return_type(quote(do: maybe_path()),
             callables: callables
           ) ==
             return_type

    assert Paths.callable_return_type(quote(do: Canvas.draw_rect(rect)),
             callables: callables
           ) ==
             return_type

    assert Paths.callable_return_type(quote(do: missing()), callables: callables) ==
             nil
  end
end
