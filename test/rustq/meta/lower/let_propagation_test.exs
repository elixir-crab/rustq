defmodule RustQ.Meta.Lower.LetPropagationTest do
  use ExUnit.Case, async: true

  alias RustQ.Binding.Callable
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  import RustQ.Meta.LowerCase

  test "infers let RHS propagation when pattern type is known" do
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
          value = maybe_path()
          :ok
        end,
        unit_type(),
        %{value: path_type},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path}
        ]
      )

    assert [
             %AST.Let{
               pattern: %AST.PatVar{name: :value},
               expr: %AST.Try{expr: %AST.LocalCall{name: :maybe_path}}
             },
             %AST.Return{}
           ] = statements
  end

  test "infers let propagation from downstream callable argument type" do
    tile_mode = %Type{kind: :type, rust: "TileMode", ast: %AST.TypePath{parts: [:TileMode]}}

    nif_tile_mode = %Type{
      kind: :nif_result,
      rust: "NifResult<TileMode>",
      ast: %AST.TypeNifResult{inner: tile_mode.ast},
      meta: %{inner: tile_mode}
    }

    atom_type = %Type{kind: :atom, rust: "Atom", ast: %AST.TypePath{parts: [:Atom]}}

    statements =
      Lower.quoted_body(
        quote do
          mode = decode_mode(atom)
          consume_mode(mode)
          :ok
        end,
        unit_type(),
        %{atom: atom_type},
        callables: [
          %Callable{
            name: "decode_mode",
            kind: :function,
            args: [%{name: "atom", type: atom_type, syn: nil}],
            returns: nif_tile_mode
          },
          %Callable{
            name: "consume_mode",
            kind: :function,
            args: [%{name: "mode", type: tile_mode, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.Let{
               pattern: %AST.PatVar{name: :mode},
               expr: %AST.Try{expr: %AST.LocalCall{name: :decode_mode}}
             },
             %AST.ExprStmt{expr: %AST.LocalCall{name: :consume_mode}},
             %AST.Return{}
           ] = statements
  end

  test "infers let propagation from downstream path call argument inside statement clauses" do
    tile_mode = %Type{kind: :type, rust: "TileMode", ast: %AST.TypePath{parts: [:TileMode]}}

    nif_tile_mode = %Type{
      kind: :nif_result,
      rust: "NifResult<TileMode>",
      ast: %AST.TypeNifResult{inner: tile_mode.ast},
      meta: %{inner: tile_mode}
    }

    atom_type = %Type{kind: :atom, rust: "Atom", ast: %AST.TypePath{parts: [:Atom]}}
    matrix_type = %Type{kind: :type, rust: "Matrix", ast: %AST.TypePath{parts: [:Matrix]}}

    option_matrix_type = %Type{
      kind: :option,
      rust: "Option<Matrix>",
      ast: %AST.TypeOption{inner: matrix_type.ast},
      meta: %{inner: matrix_type}
    }

    nif_option_matrix_type = %Type{
      kind: :nif_result,
      rust: "NifResult<Option<Matrix>>",
      ast: %AST.TypeNifResult{inner: option_matrix_type.ast},
      meta: %{inner: option_matrix_type}
    }

    effect_type = %Type{
      kind: :type,
      rust: "RuntimeEffect",
      ast: %AST.TypePath{parts: [:RuntimeEffect]}
    }

    image_type = %Type{kind: :type, rust: "Image", ast: %AST.TypePath{parts: [:Image]}}

    nif_effect_type = %Type{
      kind: :nif_result,
      rust: "NifResult<RuntimeEffect>",
      ast: %AST.TypeNifResult{inner: effect_type.ast},
      meta: %{inner: effect_type}
    }

    nif_image_type = %Type{
      kind: :nif_result,
      rust: "NifResult<Image>",
      ast: %AST.TypeNifResult{inner: image_type.ast},
      meta: %{inner: image_type}
    }

    tile_pair_type = %Type{
      kind: :tuple,
      rust: "(TileMode, TileMode)",
      ast: %AST.TypeRaw{source: "(TileMode, TileMode)"},
      meta: %{elements: [tile_mode, tile_mode]}
    }

    option_tile_pair_type = %Type{
      kind: :option,
      rust: "Option<(TileMode, TileMode)>",
      ast: %AST.TypeOption{inner: tile_pair_type.ast},
      meta: %{inner: tile_pair_type}
    }

    into_option_tile_pair_type = %Type{
      kind: :impl_trait,
      rust: "impl Into<Option<(TileMode, TileMode)>>",
      ast: %AST.TypeRaw{source: "impl Into<Option<(TileMode, TileMode)>>"},
      meta: %{
        traits: [
          %Type{
            kind: :type,
            rust: "Into<Option<(TileMode, TileMode)>>",
            ast: %AST.TypePath{parts: [:Into]},
            meta: %{syn_name: "Into", args: [option_tile_pair_type]}
          }
        ]
      }
    }

    into_atom_type = %Type{
      kind: :impl_trait,
      rust: "impl Into<Atom>",
      ast: %AST.TypeRaw{source: "impl Into<Atom>"},
      meta: %{
        traits: [
          %Type{
            kind: :type,
            rust: "Into<Atom>",
            ast: %AST.TypePath{parts: [:Into]},
            meta: %{syn_name: "Into", args: [atom_type]}
          }
        ]
      }
    }

    into_option_matrix_ref_type = %Type{
      kind: :impl_trait,
      rust: "impl Into<Option<&Matrix>>",
      ast: %AST.TypeRaw{source: "impl Into<Option<&Matrix>>"},
      meta: %{
        traits: [
          %Type{
            kind: :type,
            rust: "Into<Option<&Matrix>>",
            ast: %AST.TypePath{parts: [:Into]},
            meta: %{
              syn_name: "Into",
              args: [
                %Type{
                  kind: :option,
                  rust: "Option<&Matrix>",
                  ast: %AST.TypeOption{inner: %AST.TypeRef{inner: matrix_type.ast}},
                  meta: %{
                    inner: %Type{
                      kind: :ref,
                      rust: "&Matrix",
                      ast: %AST.TypeRef{inner: matrix_type.ast},
                      meta: %{inner: matrix_type}
                    }
                  }
                }
              ]
            }
          }
        ]
      }
    }

    statements =
      Lower.quoted_body(
        quote do
          if tag == atom do
            effect = unwrap!(runtime_effect_from_term(atom))
            image = unwrap!(image_from_term(atom))
            mode = GeneratedEnums.decode_mode(atom)
            mode_2 = GeneratedEnums.decode_mode(atom)
            matrix = optional_matrix_from_term(atom)

            effect.make_shader(atom, atom, matrix.as_ref())
            image.to_shader({mode, mode_2}, atom, matrix.as_ref())

            Shader.linear_gradient(
              atom,
              atom,
              atom,
              mode,
              none(),
              matrix.as_ref()
            )
          end

          :ok
        end,
        unit_type(),
        %{atom: atom_type, tag: atom_type, mode: atom_type},
        callables: [
          %Callable{
            name: "decode_mode",
            kind: :function,
            target: "GeneratedEnums",
            args: [%{name: "atom", type: atom_type, syn: nil}],
            returns: nif_tile_mode
          },
          %Callable{
            name: "runtime_effect_from_term",
            kind: :function,
            args: [%{name: "term", type: atom_type, syn: nil}],
            returns: nif_effect_type
          },
          %Callable{
            name: "image_from_term",
            kind: :function,
            args: [%{name: "term", type: atom_type, syn: nil}],
            returns: nif_image_type
          },
          %Callable{
            name: "optional_matrix_from_term",
            kind: :function,
            args: [%{name: "term", type: atom_type, syn: nil}],
            returns: nif_option_matrix_type
          },
          %Callable{
            name: "make_shader",
            kind: :method,
            target: "RuntimeEffect",
            args: [
              %{name: "uniforms", type: atom_type, syn: nil},
              %{name: "children", type: atom_type, syn: nil},
              %{name: "matrix", type: into_option_matrix_ref_type, syn: nil}
            ],
            returns: unit_type()
          },
          %Callable{
            name: "to_shader",
            kind: :method,
            target: "Image",
            args: [
              %{name: "tile_modes", type: into_option_tile_pair_type, syn: nil},
              %{name: "sampling", type: into_atom_type, syn: nil},
              %{name: "matrix", type: into_option_matrix_ref_type, syn: nil}
            ],
            returns: unit_type()
          },
          %Callable{
            name: "linear_gradient",
            kind: :method,
            target: "Shader",
            args: [
              %{name: "points", type: atom_type, syn: nil},
              %{name: "colors", type: atom_type, syn: nil},
              %{name: "positions", type: atom_type, syn: nil},
              %{name: "mode", type: tile_mode, syn: nil},
              %{name: "flags", type: atom_type, syn: nil},
              %{name: "matrix", type: into_option_matrix_ref_type, syn: nil}
            ],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.ExprStmt{
               expr: %AST.If{
                 then: [
                   %AST.Let{
                     pattern: %AST.PatVar{name: :effect},
                     expr: %AST.Try{expr: %AST.LocalCall{name: :runtime_effect_from_term}}
                   },
                   %AST.Let{
                     pattern: %AST.PatVar{name: :image},
                     expr: %AST.Try{expr: %AST.LocalCall{name: :image_from_term}}
                   },
                   %AST.Let{
                     pattern: %AST.PatVar{name: :mode},
                     expr: %AST.Try{
                       expr: %AST.PathCall{
                         path: %AST.Path{parts: [:generated_enums, :decode_mode]}
                       }
                     }
                   },
                   %AST.Let{
                     pattern: %AST.PatVar{name: :mode_2},
                     expr: %AST.Try{
                       expr: %AST.PathCall{
                         path: %AST.Path{parts: [:generated_enums, :decode_mode]}
                       }
                     }
                   },
                   %AST.Let{
                     pattern: %AST.PatVar{name: :matrix},
                     expr: %AST.Try{expr: %AST.LocalCall{name: :optional_matrix_from_term}}
                   },
                   %AST.ExprStmt{expr: %AST.MethodCall{method: :make_shader}},
                   %AST.ExprStmt{expr: %AST.MethodCall{method: :to_shader}},
                   %AST.ExprStmt{
                     expr: %AST.PathCall{path: %AST.Path{parts: [:Shader, :linear_gradient]}}
                   }
                 ]
               }
             },
             %AST.Return{}
           ] = statements
  end

  test "infers tuple-pattern let propagation from callable return metadata" do
    color_vec = %Type{kind: :type, rust: "Vec<Color>", ast: %AST.TypePath{parts: [:Vec]}}

    positions = %Type{
      kind: :option,
      rust: "Option<Vec<f32>>",
      ast: %AST.TypeOption{inner: %AST.TypePath{parts: [:Vec]}}
    }

    tuple = %Type{
      kind: :tuple,
      rust: "(Vec<Color>, Option<Vec<f32>>)",
      ast: %AST.TypeRaw{source: "(Vec<Color>, Option<Vec<f32>>)"},
      meta: %{elements: [color_vec, positions]}
    }

    nif_tuple = %Type{
      kind: :nif_result,
      rust: "NifResult<(Vec<Color>, Option<Vec<f32>>)",
      ast: %AST.TypeNifResult{inner: tuple.ast},
      meta: %{inner: tuple}
    }

    stops_type = %Type{kind: :type, rust: "Vec<Term>", ast: %AST.TypePath{parts: [:Vec]}}

    statements =
      Lower.quoted_body(
        quote do
          {colors, positions} = decode_stops(stops)
          :ok
        end,
        unit_type(),
        %{stops: stops_type},
        callables: [
          %Callable{
            name: "decode_stops",
            kind: :function,
            args: [%{name: "stops", type: stops_type, syn: nil}],
            returns: nif_tuple
          }
        ]
      )

    assert [
             %AST.Let{
               pattern: %AST.PatTuple{},
               expr: %AST.Try{expr: %AST.LocalCall{name: :decode_stops}}
             },
             %AST.Return{}
           ] = statements
  end

  test "infers let propagation from downstream receiver method type" do
    image_type = %Type{kind: :type, rust: "Image", ast: %AST.TypePath{parts: [:Image]}}
    shader_type = %Type{kind: :type, rust: "Shader", ast: %AST.TypePath{parts: [:Shader]}}
    term_type = %Type{kind: :term, rust: "Term", ast: %AST.TypePath{parts: [:Term]}}

    statements =
      Lower.quoted_body(
        quote do
          image = image_from_term(term)
          image.to_shader()
          :ok
        end,
        %Type{
          kind: :nif_result,
          rust: "NifResult<()>",
          ast: %AST.TypeNifResult{inner: %AST.TypeUnit{}}
        },
        %{term: term_type},
        callables: [
          %Callable{
            name: "image_from_term",
            kind: :function,
            args: [%{name: "term", type: term_type, syn: nil}],
            returns: %Type{
              kind: :nif_result,
              rust: "NifResult<Image>",
              ast: %AST.TypeNifResult{inner: image_type.ast},
              meta: %{inner: image_type}
            }
          },
          %Callable{
            name: "to_shader",
            kind: :method,
            target: "Image",
            args: [%{name: "self", type: image_type, syn: nil}],
            returns: %Type{
              kind: :option,
              rust: "Option<Shader>",
              ast: %AST.TypeOption{inner: shader_type.ast},
              meta: %{inner: shader_type}
            }
          }
        ]
      )

    assert [
             %AST.Let{
               pattern: %AST.PatVar{name: :image},
               expr: %AST.Try{expr: %AST.LocalCall{name: :image_from_term}}
             },
             %AST.ExprStmt{expr: %AST.MethodCall{method: :to_shader}},
             %AST.Return{expr: %AST.Ok{}}
           ] = statements
  end

  test "infers vector push argument propagation from downstream IntoIterator item type" do
    image_filter_type = %Type{
      kind: :type,
      rust: "ImageFilter",
      ast: %AST.TypePath{parts: [:ImageFilter]}
    }

    option_image_filter_type = %Type{
      kind: :option,
      rust: "Option<ImageFilter>",
      ast: %AST.TypeOption{inner: image_filter_type.ast},
      meta: %{inner: image_filter_type}
    }

    into_iterator_type = %Type{
      kind: :impl_trait,
      rust: "impl IntoIterator<Item = Option<ImageFilter>>",
      ast: %AST.TypeRaw{source: "impl IntoIterator<Item = Option<ImageFilter>>"},
      meta: %{
        traits: [
          %Type{
            kind: :type,
            rust: "IntoIterator",
            ast: %AST.TypePath{parts: [:IntoIterator]},
            meta: %{
              syn_name: "IntoIterator",
              assoc: %{"Item" => option_image_filter_type},
              args: []
            }
          }
        ]
      }
    }

    term_type = %Type{kind: :term, rust: "Term", ast: %AST.TypePath{parts: [:Term]}}

    statements =
      Lower.quoted_body(
        quote do
          mapped_filters = Vec.with_capacity(filters.len())

          for filter <- filters do
            mapped_filters.push(optional_image_filter_from_term(filter))
          end

          ImageFilters.merge(mapped_filters, none())
          :ok
        end,
        unit_type(),
        %{
          filters: %Type{
            kind: :vec,
            rust: "Vec<Term>",
            ast: %AST.TypeVec{inner: term_type.ast},
            meta: %{inner: term_type}
          }
        },
        callables: [
          %Callable{
            name: "optional_image_filter_from_term",
            kind: :function,
            args: [%{name: "term", type: term_type, syn: nil}],
            returns: %Type{
              kind: :nif_result,
              rust: "NifResult<Option<ImageFilter>>",
              ast: %AST.TypeNifResult{inner: option_image_filter_type.ast},
              meta: %{inner: option_image_filter_type}
            }
          },
          %Callable{
            name: "merge",
            kind: :function,
            target: "image_filters",
            args: [
              %{name: "filters", type: into_iterator_type, syn: nil},
              %{name: "crop_rect", type: term_type, syn: nil}
            ],
            returns: %Type{
              kind: :option,
              rust: "Option<ImageFilter>",
              ast: %AST.TypeOption{inner: image_filter_type.ast},
              meta: %{inner: image_filter_type}
            }
          }
        ]
      )

    assert [
             %AST.Let{},
             %AST.For{
               body: [
                 %AST.ExprStmt{
                   expr: %AST.MethodCall{
                     method: :push,
                     args: [
                       %AST.Try{expr: %AST.LocalCall{name: :optional_image_filter_from_term}}
                     ]
                   }
                 }
               ]
             },
             %AST.ExprStmt{expr: %AST.PathCall{}},
             %AST.Return{expr: %AST.Tuple{values: []}}
           ] = statements
  end

  test "infers let propagation through as_slice arguments" do
    atom_type = %Type{kind: :atom, rust: "Atom", ast: %AST.TypePath{parts: [:Atom]}}
    child_type = %Type{kind: :type, rust: "ChildPtr", ast: %AST.TypePath{parts: [:ChildPtr]}}

    vec_child_type = %Type{
      kind: :vec,
      rust: "Vec<ChildPtr>",
      ast: %AST.TypeVec{inner: child_type.ast},
      meta: %{inner: child_type}
    }

    slice_child_type = %Type{
      kind: :slice,
      rust: "[ChildPtr]",
      ast: %AST.TypeSlice{inner: child_type.ast},
      meta: %{inner: child_type}
    }

    ref_slice_child_type = %Type{
      kind: :ref,
      rust: "&[ChildPtr]",
      ast: %AST.TypeRef{inner: slice_child_type.ast},
      meta: %{inner: slice_child_type}
    }

    into_option_ref_slice_child_type = %Type{
      kind: :impl_trait,
      rust: "impl Into<Option<&[ChildPtr]>>",
      ast: %AST.TypeRaw{source: "impl Into<Option<&[ChildPtr]>>"},
      meta: %{
        traits: [
          %Type{
            kind: :type,
            rust: "Into<Option<&[ChildPtr]>>",
            ast: %AST.TypePath{parts: [:Into]},
            meta: %{
              syn_name: "Into",
              args: [
                %Type{
                  kind: :option,
                  rust: "Option<&[ChildPtr]>",
                  ast: %AST.TypeOption{inner: ref_slice_child_type.ast},
                  meta: %{inner: ref_slice_child_type}
                }
              ]
            }
          }
        ]
      }
    }

    statements =
      Lower.quoted_body(
        quote do
          children = runtime_children(term)
          effect.make_shader(children.as_slice())
          :ok
        end,
        unit_type(),
        %{
          term: atom_type,
          effect: %Type{
            kind: :type,
            rust: "RuntimeEffect",
            ast: %AST.TypePath{parts: [:RuntimeEffect]}
          }
        },
        callables: [
          %Callable{
            name: "runtime_children",
            kind: :function,
            args: [%{name: "term", type: atom_type, syn: nil}],
            returns: %Type{
              kind: :nif_result,
              rust: "NifResult<Vec<ChildPtr>>",
              ast: %AST.TypeNifResult{inner: vec_child_type.ast},
              meta: %{inner: vec_child_type}
            }
          },
          %Callable{
            name: "make_shader",
            kind: :method,
            target: "RuntimeEffect",
            args: [%{name: "children", type: into_option_ref_slice_child_type, syn: nil}],
            returns: unit_type()
          }
        ]
      )

    assert [
             %AST.Let{
               pattern: %AST.PatVar{name: :children},
               expr: %AST.Try{expr: %AST.LocalCall{name: :runtime_children}}
             },
             %AST.ExprStmt{expr: %AST.MethodCall{method: :make_shader}},
             %AST.Return{}
           ] = statements
  end

  test "does not fail receiver inference for non-simple upstream target names" do
    term_type = %Type{kind: :term, rust: "Term", ast: %AST.TypePath{parts: [:Term]}}

    statements =
      Lower.quoted_body(
        quote do
          values = Vec.new()
          values.len()
          :ok
        end,
        %Type{
          kind: :nif_result,
          rust: "NifResult<()>",
          ast: %AST.TypeNifResult{inner: %AST.TypeUnit{}}
        },
        %{},
        callables: [
          %Callable{
            name: "new",
            kind: :function,
            target: "Vec",
            args: [],
            returns: term_type
          },
          %Callable{
            name: "len",
            kind: :method,
            target: "GradientShaderColors < '_ >",
            args: [%{name: "self", type: term_type, syn: nil}],
            returns: %Type{kind: :usize, rust: "usize", ast: %AST.TypePath{parts: [:usize]}}
          }
        ]
      )

    assert [%AST.Let{}, %AST.ExprStmt{expr: %AST.MethodCall{method: :len}}, %AST.Return{}] =
             statements
  end

  test "infers vector push argument propagation from downstream return type" do
    color_type = %Type{kind: :type, rust: "Color", ast: %AST.TypePath{parts: [:Color]}}

    vec_color_type = %Type{
      kind: :vec,
      rust: "Vec<Color>",
      ast: %AST.TypeVec{inner: color_type.ast},
      meta: %{inner: color_type}
    }

    return_type = %Type{
      kind: :nif_result,
      rust: "NifResult<Vec<Color>>",
      ast: %AST.TypeNifResult{inner: vec_color_type.ast},
      meta: %{inner: vec_color_type}
    }

    term_type = %Type{kind: :term, rust: "Term", ast: %AST.TypePath{parts: [:Term]}}

    statements =
      Lower.quoted_body(
        quote do
          colors = Vec.with_capacity(stops.len())

          for stop <- stops do
            colors.push(decode_color(stop))
          end

          {:ok, colors}
        end,
        return_type,
        %{
          stops: %Type{
            kind: :vec,
            rust: "Vec<Term>",
            ast: %AST.TypeVec{inner: term_type.ast},
            meta: %{inner: term_type}
          }
        },
        callables: [
          %Callable{
            name: "decode_color",
            kind: :function,
            args: [%{name: "term", type: term_type, syn: nil}],
            returns: %Type{
              kind: :nif_result,
              rust: "NifResult<Color>",
              ast: %AST.TypeNifResult{inner: color_type.ast},
              meta: %{inner: color_type}
            }
          }
        ]
      )

    assert [
             %AST.Let{},
             %AST.For{
               body: [
                 %AST.ExprStmt{
                   expr: %AST.MethodCall{
                     method: :push,
                     args: [%AST.Try{expr: %AST.LocalCall{name: :decode_color}}]
                   }
                 }
               ]
             },
             %AST.Return{expr: %AST.Ok{expr: %AST.Var{name: :colors}}}
           ] = statements
  end

  test "infers assignment RHS propagation when target type is known" do
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
          assign!(value, maybe_path())
          :ok
        end,
        unit_type(),
        %{value: path_type},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path}
        ]
      )

    assert [
             %AST.Assign{
               target: %AST.Var{name: :value},
               expr: %AST.Try{expr: %AST.LocalCall{name: :maybe_path}}
             },
             %AST.Return{}
           ] = statements
  end

  test "does not infer propagation for let RHS when pattern type is unknown" do
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
          value = maybe_path()
          :ok
        end,
        unit_type(),
        %{},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path}
        ]
      )

    assert [
             %AST.Let{
               pattern: %AST.PatVar{name: :value},
               expr: %AST.LocalCall{name: :maybe_path}
             },
             %AST.Return{}
           ] = statements
  end
end
