defmodule RustQ.Meta.TypingTest do
  use ExUnit.Case, async: true

  alias RustQ.Binding.Callable
  alias RustQ.Meta.Type
  alias RustQ.Meta.Typing
  alias RustQ.Rust.AST

  defp type(kind, rust) do
    %Type{kind: kind, rust: rust, ast: %AST.TypePath{parts: [String.to_atom(rust)]}}
  end

  test "infers known clone and dereference results without guessing foreign clones" do
    string = Type.parse(quote(do: String.t()), %{})
    reference = Type.parse(quote(do: R.ref(String.t())), %{})
    unknown = Type.parse(quote(do: R.ref(External.t())), %{})
    nested = Type.parse(quote(do: R.ref(R.ref(String.t()))), %{})

    env =
      Typing.env(vars: %{owned: string, borrowed: reference, foreign: unknown, nested: nested})

    assert Typing.synth(quote(do: owned.clone()), env) == string
    assert Typing.synth(quote(do: borrowed.clone()), env).ast == string.ast
    assert Typing.synth(quote(do: deref(borrowed)), env).ast == string.ast
    assert Typing.synth(quote(do: deref(nested)), env).ast == reference.ast
    assert Typing.synth(quote(do: foreign.clone()), env) == nil
    assert Typing.synth(quote(do: nested.clone()), env) == nil
  end

  test "synthesizes variables and local callable return types from explicit env" do
    path = type(:type, "Path")

    option_path = %Type{
      kind: :option,
      rust: "Option<Path>",
      ast: %AST.TypeOption{inner: path.ast},
      meta: %{inner: path}
    }

    env =
      Typing.env(
        vars: %{path: path},
        callables: [
          %Callable{name: "maybe_path", kind: :function, args: [], returns: option_path}
        ]
      )

    assert Typing.synth(quote(do: path), env) == path
    assert Typing.synth(quote(do: maybe_path()), env) == option_path
  end

  test "synthesizes Result.ok as an option of the success type" do
    term = type(:type, "Term")

    result = %Type{
      kind: :nif_result,
      rust: "NifResult<Term>",
      ast: %AST.TypeNifResult{inner: term.ast},
      meta: %{inner: term}
    }

    expected = %Type{
      kind: :option,
      rust: "Option<Term>",
      ast: %AST.TypeOption{inner: term.ast},
      meta: %{inner: term}
    }

    env =
      Typing.env(
        callables: [%Callable{name: "lookup", kind: :function, args: [], returns: result}]
      )

    assert Typing.synth(quote(do: lookup().ok()), env) == expected
    assert %Typing.Check{coercion: :none} = Typing.check(quote(do: lookup().ok()), expected, env)
  end

  test "synthesizes Option.filter as the original option type" do
    term = type(:term, "Term")

    option = %Type{
      kind: :option,
      rust: "Option<Term>",
      ast: %AST.TypeOption{inner: term.ast},
      meta: %{inner: term}
    }

    env =
      Typing.env(callables: [%Callable{name: "get", kind: :function, args: [], returns: option}])

    expression = quote(do: get().filter(fn value -> value.is_map() end))

    assert Typing.synth(expression, env) == option
    assert %Typing.Check{coercion: :none} = Typing.check(expression, option, env)
  end

  test "synthesizes unambiguous parent-module free-function returns" do
    string = type(:type, "String")

    nif_string = %Type{
      kind: :nif_result,
      rust: "NifResult<String>",
      ast: %AST.TypeNifResult{inner: string.ast},
      meta: %{inner: string}
    }

    env =
      Typing.env(
        vars: %{term: type(:type, "Term")},
        callables: [
          %Callable{
            name: "string_field",
            kind: :function,
            target: "helpers",
            args: [
              %{name: "term", type: type(:type, "Term"), syn: nil},
              %{name: "key", type: type(:type, "str"), syn: nil}
            ],
            returns: nif_string
          }
        ]
      )

    assert Typing.synth(quote(do: Super.string_field(term, "source")), env) == nif_string
  end

  test "propagates a fallible string into impl AsRef<str>" do
    string = type(:type, "String")

    nif_string = %Type{
      kind: :nif_result,
      rust: "NifResult<String>",
      ast: %AST.TypeNifResult{inner: string.ast},
      meta: %{inner: string}
    }

    str = type(:type, "str")

    as_ref_string = %Type{
      kind: :impl_trait,
      rust: "impl AsRef<str>",
      ast: %AST.TypeRaw{source: "impl AsRef<str>"},
      meta: %{traits: [%Type{meta: %{syn_name: "AsRef", args: [str]}}]}
    }

    env =
      Typing.env(
        callables: [
          %Callable{name: "string_field", kind: :function, args: [], returns: nif_string}
        ]
      )

    assert %Typing.Check{type: ^nif_string, coercion: :propagate} =
             Typing.check(quote(do: string_field()), as_ref_string, env)
  end

  test "checks propagation, option wrapping, and borrow coercions" do
    color = type(:type, "Color")

    nif_color = %Type{
      kind: :nif_result,
      rust: "NifResult<Color>",
      ast: %AST.TypeNifResult{inner: color.ast},
      meta: %{inner: color}
    }

    option_color = %Type{
      kind: :option,
      rust: "Option<Color>",
      ast: %AST.TypeOption{inner: color.ast},
      meta: %{inner: color}
    }

    ref_color = %Type{
      kind: :ref,
      rust: "&Color",
      ast: %AST.TypeRef{inner: color.ast},
      meta: %{inner: color}
    }

    env =
      Typing.env(
        vars: %{color: color},
        callables: [%Callable{name: "decode", kind: :function, args: [], returns: nif_color}]
      )

    assert %Typing.Check{coercion: :propagate} = Typing.check(quote(do: decode()), color, env)
    assert %Typing.Check{coercion: :some} = Typing.check(quote(do: color), option_color, env)
    assert %Typing.Check{coercion: :borrow} = Typing.check(quote(do: color), ref_color, env)

    integer = type(:i64, "i64")
    list_env = Typing.env(vars: %{tail: Type.slice_ref(integer)})

    assert %Typing.Check{coercion: :to_vec} =
             Typing.check(quote(do: tail), Type.vec(integer), list_env)
  end

  test "infers let expectations from vars and tuple-return calls" do
    left = type(:u32, "u32")
    right = type(:u32, "u32")

    tuple = %Type{
      kind: :tuple,
      rust: "(u32, u32)",
      ast: %AST.TypeRaw{source: "(u32, u32)"},
      meta: %{elements: [left, right]}
    }

    result_tuple = %Type{
      kind: :nif_result,
      rust: "NifResult<(u32, u32)>",
      ast: %AST.TypeNifResult{inner: tuple.ast},
      meta: %{inner: tuple}
    }

    env =
      Typing.env(
        vars: %{known: left},
        callables: [%Callable{name: "pair", kind: :function, args: [], returns: result_tuple}]
      )

    assert Typing.expected_for_let(quote(do: known), quote(do: ignored()), env) == left
    assert Typing.expected_for_let(quote(do: {a, b}), quote(do: pair()), env) == tuple
    assert Typing.expected_for_let(quote(do: unknown), quote(do: ignored()), env) == nil
  end

  test "synthesizes cast target types" do
    assert %Type{kind: :u8, rust: "u8"} =
             Typing.synth(quote(do: cast(value, RustQ.Type.u8())), Typing.env())
  end

  test "returns struct field expectations" do
    x = type(:f32, "f32")
    y = type(:f32, "f32")

    point = %Type{
      kind: :struct,
      rust: "Point",
      ast: %AST.TypePath{parts: [:Point]},
      meta: %{fields: [{:x, x, :required}, {:y, y, :required}]}
    }

    assert Typing.struct_field_type(point, :x) == x
    assert Typing.struct_field_type(point, :missing) == nil
  end

  test "downstream let inference stores value types for borrowed call arguments" do
    value = type(:u32, "u32")

    ref_value = %Type{
      kind: :mut_ref,
      rust: "&mut u32",
      ast: %AST.TypeRef{inner: value.ast, mutable: true},
      meta: %{inner: value}
    }

    env =
      Typing.env(
        vars: %{value: value},
        callables: [
          %Callable{
            name: "touch",
            kind: :function,
            args: [%{name: "value", type: ref_value}],
            returns: nil
          }
        ]
      )

    inferred =
      Typing.infer_downstream_let_types(
        [
          quote(do: local = value),
          quote(do: touch(local))
        ],
        env,
        %{
          local_argument_types: fn
            :touch, 1 -> [ref_value]
            _name, _arity -> nil
          end
        }
      )

    assert inferred == %{local: value}
  end

  test "delegates downstream let inference through explicit env" do
    mode = type(:type, "Mode")

    env =
      Typing.env(
        callables: [
          %Callable{
            name: "consume",
            kind: :function,
            args: [%{name: "mode", type: mode}],
            returns: nil
          }
        ]
      )

    inferred =
      Typing.infer_downstream_let_types(
        [
          quote(do: mode = decode()),
          quote(do: consume(mode))
        ],
        env,
        %{
          local_argument_types: fn
            :consume, 1 -> [mode]
            _name, _arity -> nil
          end
        }
      )

    assert inferred == %{mode: mode}
  end

  test "uses safe no-op callbacks when none are supplied" do
    assert Typing.infer_downstream_let_types(
             [quote(do: value = decode())],
             Typing.env()
           ) == %{}
  end

  test "checks propagation through impl Into option expectations" do
    image_filter = type(:type, "ImageFilter")

    option_filter = %Type{
      kind: :option,
      rust: "Option<ImageFilter>",
      ast: %AST.TypeOption{inner: image_filter.ast},
      meta: %{inner: image_filter}
    }

    nif_option_filter = %Type{
      kind: :nif_result,
      rust: "NifResult<Option<ImageFilter>>",
      ast: %AST.TypeNifResult{inner: option_filter.ast},
      meta: %{inner: option_filter}
    }

    into_option_filter = %Type{
      kind: :impl_trait,
      rust: "impl Into<Option<ImageFilter>>",
      ast: %AST.TypeRaw{source: "impl Into<Option<ImageFilter>>"},
      meta: %{
        traits: [
          %Type{
            kind: :type,
            rust: "Into<Option<ImageFilter>>",
            ast: %AST.TypePath{parts: [:Into]},
            meta: %{syn_name: "Into", args: [option_filter]}
          }
        ]
      }
    }

    env =
      Typing.env(
        callables: [
          %Callable{name: "decode_filter", kind: :function, args: [], returns: nif_option_filter}
        ]
      )

    assert %Typing.Check{coercion: :propagate} =
             Typing.check(quote(do: decode_filter()), into_option_filter, env)
  end

  test "synthesizes field access from struct metadata" do
    kind = type(:type, "KiwiSkipKind")

    field = %Type{
      kind: :struct,
      rust: "KiwiSkipField",
      ast: %AST.TypePath{parts: [:KiwiSkipField]},
      meta: %{fields: [{:kind, kind, :required}]}
    }

    ref_field = %Type{
      kind: :ref,
      rust: "&KiwiSkipField",
      ast: %AST.TypeRef{inner: field.ast},
      meta: %{inner: field}
    }

    env = Typing.env(vars: %{field: field, ref_field: ref_field})

    assert Typing.synth(quote(do: field.kind), env) == kind
    assert Typing.synth(quote(do: ref_field.kind), env) == kind
  end

  test "synthesizes method calls through receiver type" do
    paint = type(:type, "Paint")
    color = type(:type, "Color")

    env =
      Typing.env(
        vars: %{paint: paint},
        callables: [
          %Callable{
            name: "color",
            kind: :method,
            target: "Paint",
            args: [%{name: "self", type: paint, syn: nil}],
            returns: color
          }
        ]
      )

    assert Typing.synth(quote(do: paint.color()), env) == color
  end

  test "synthesizes method calls through raw receiver type" do
    decoder = %Type{kind: :raw, rust: "Decoder<'_>", ast: %AST.TypeRaw{source: "Decoder<'_>"}}
    count = type(:u32, "u32")

    env =
      Typing.env(
        vars: %{decoder: decoder},
        callables: [
          %Callable{
            name: "read_var_uint",
            kind: :method,
            target: "Decoder",
            args: [%{name: "self", type: decoder, syn: nil}],
            returns: count
          }
        ]
      )

    assert Typing.synth(quote(do: decoder.read_var_uint()), env) == count
  end

  test "checks exact compatible values without coercion" do
    count = type(:u32, "u32")
    env = Typing.env(vars: %{count: count})

    assert %Typing.Check{type: ^count, coercion: :none} =
             Typing.check(quote(do: count), count, env)
  end
end
