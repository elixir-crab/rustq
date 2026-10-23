defmodule RustQ.Meta.RustMacroTest do
  use RustQ.Test, async: true

  alias RustQ.Diagnostic
  alias RustQ.Meta.RustMacro
  alias RustQ.Meta.RustMacro.Definition

  test "normalizes defrustmacro arguments into Rust fragments" do
    [definition] =
      RustMacro.definitions([
        {quote(do: field(term, name, type: :ty)), quote(do: term), nil}
      ])

    assert %Definition{
             name: :field,
             args: [term: :expr, name: :expr, type: :ty],
             rust_module: nil
           } = definition
  end

  test "indexes macro definitions and rejects duplicates" do
    [definition] = RustMacro.definitions([{quote(do: identity(value)), quote(do: value), nil}])

    assert %{identity: ^definition} = RustMacro.index!([definition])

    assert_raise Diagnostic.Error, ~r/duplicate defrustmacro identity/, fn ->
      RustMacro.index!([definition, definition])
    end
  end

  test "rejects duplicate argument names" do
    assert_raise Diagnostic.Error, ~r/duplicate argument value in defrustmacro bad/, fn ->
      RustMacro.definitions([{quote(do: bad(value, value)), quote(do: value), nil}])
    end
  end

  test "emits compact macro_rules items from Rusty-Elixir bodies" do
    [definition] =
      RustMacro.definitions([
        {quote(do: identity(value)), quote(do: value), [:helpers]}
      ])

    [item] = RustMacro.items([definition], %{}, __ENV__, [], RustMacro.index!([definition]))

    assert item.rust_module == [:helpers]
    assert item.ast.source =~ "macro_rules! identity"
    assert item.ast.source =~ "$value:expr"
    assert item.ast.source =~ "$value"
    refute item.ast.source =~ "$value "
  end

  describe "defrustmacro" do
    alias RustQ.Diagnostic
    alias RustQ.Meta.AST, as: MetaAST

    test "defrustmacro defines Rust macros from Rusty-Elixir bodies" do
      defmodule DefrustMacroFieldCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @spec required_field(R.term(), binary()) :: R.nif_result(R.term())
        defrust required_field(term, _name) do
          {:ok, term}
        end

        defrustmacro field(term, name, type: :ty) do
          decode_as!(required_field(term, name), type)
        end

        @spec decode(R.term()) :: R.nif_result(R.u32())
        defrust decode(term) do
          field!(term, "value", R.u32())
        end
      end

      source = DefrustMacroFieldCase.__rustq_source__()

      assert source =~ "macro_rules! field"
      assert source =~ "$term:expr"
      assert source =~ "$type:ty"
      assert source =~ "required_field($term, $name)?.decode::<$type>()?"
      assert source =~ ~s|field!(term, "value", u32)|
      assert RustQ.valid?(source, "defrustmacro_field.rs")
    end

    test "defrustmacro can emit item macros from inner defrust bodies and repeat groups" do
      defmodule DefrustMacroItemCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @type field :: %{
                required(:id) => R.u32(),
                required(:name) => R.raw(:"&'static str"),
                required(:repeated) => R.bool(),
                required(:decode) => R.raw(:"fn()")
              }

        @spec build_fields(R.slice(R.path(:Field))) :: R.nif_result(R.unit())
        defrust build_fields(_fields) do
          :ok
        end

        defrustmacro descriptor(
                       fn: name(:ident),
                       fields:
                         repeat do
                           field_id(:literal)
                           field_name(:literal)
                           field_mode(:ident)
                           field_decode(:ident)
                         end
                     ) do
          @spec name() :: R.nif_result(R.unit())
          defrust name() do
            build_fields(
              ref(
                array([
                  repeat fields do
                    struct_literal(Field,
                      id: field_id,
                      name: field_name,
                      repeated: repeated!(field_mode),
                      decode: field_decode
                    )
                  end
                ])
              )
            )
          end
        end
      end

      source = DefrustMacroItemCase.__rustq_source__()

      assert source =~ "macro_rules! descriptor"
      assert source =~ "fn $name:ident;"
      assert source =~ "fields [$("
      assert source =~ "$field_id:literal, $field_name:literal,"
      assert source =~ "fn $name() -> NifResult<()>"

      assert source =~
               "build_fields(&[$(Field { id: $field_id, name: $field_name, repeated: repeated!($field_mode), decode: $field_decode },)*])"

      assert RustQ.valid?(source, "defrustmacro_item.rs")
    end

    test "defrustmacro supports shared sparse skip descriptor field rows" do
      defmodule DefrustMacroSharedSkipFieldCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @type field :: %{
                required(:id) => R.u32(),
                required(:name) => R.raw(:"&'static str"),
                required(:repeated) => R.bool(),
                required(:decode) => R.raw(:"fn()"),
                required(:skip_repeated) => R.bool(),
                required(:skip_bytes) => R.bool(),
                required(:skip) => R.raw(:"fn()")
              }

        @spec build_fields(R.slice(R.path(:Field))) :: R.nif_result(R.unit())
        defrust build_fields(_fields) do
          :ok
        end

        defrustmacro descriptor(
                       fn: name(:ident),
                       fields:
                         repeat do
                           field_id(:literal)
                           field_name(:literal)
                           field_mode(:ident)
                           field_decode(:ident)
                           skip_repeated(:literal)
                           skip_bytes(:literal)
                           field_skip(:ident)
                         end
                     ) do
          @spec name() :: R.nif_result(R.unit())
          defrust name() do
            build_fields(
              ref(
                array([
                  repeat fields do
                    struct_literal(Field,
                      id: field_id,
                      name: field_name,
                      repeated: repeated!(field_mode),
                      decode: field_decode,
                      skip_repeated: skip_repeated,
                      skip_bytes: skip_bytes,
                      skip: field_skip
                    )
                  end
                ])
              )
            )
          end
        end
      end

      source = DefrustMacroSharedSkipFieldCase.__rustq_source__()

      assert source =~
               "fields [$(" <>
                 "$field_id:literal, $field_name:literal, $field_mode:ident, $field_decode:ident, " <>
                 "$skip_repeated:literal, $skip_bytes:literal, $field_skip:ident;)*]"

      assert RustQ.valid?(source, "defrustmacro_shared_skip_field.rs")
    end

    test "defrustmacro supports skip field descriptor rows" do
      defmodule DefrustMacroSkipFieldCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @type skip_field :: %{
                required(:id) => R.u32(),
                required(:repeated) => R.bool(),
                required(:bytes) => R.bool(),
                required(:skip) => R.raw(:SkipFn)
              }

        @spec build_fields(R.slice(R.path(:SkipField))) :: R.nif_result(R.unit())
        defrust build_fields(_fields) do
          :ok
        end

        defrustmacro descriptor(
                       fn: name(:ident),
                       skip_fields:
                         repeat do
                           field_id(:literal)
                           field_repeated(:literal)
                           field_bytes(:literal)
                           field_skip(:ident)
                         end
                     ) do
          @spec name() :: R.nif_result(R.unit())
          defrust name() do
            build_fields(
              ref(
                array([
                  repeat skip_fields do
                    struct_literal(SkipField,
                      id: field_id,
                      repeated: field_repeated,
                      bytes: field_bytes,
                      skip: field_skip
                    )
                  end
                ])
              )
            )
          end
        end
      end

      source = DefrustMacroSkipFieldCase.__rustq_source__()

      assert source =~
               "skip_fields [$(" <>
                 "$field_id:literal, $field_repeated:literal, $field_bytes:literal, $field_skip:ident;)*]"

      assert RustQ.valid?(source, "defrustmacro_skip_field.rs")
    end

    test "builds semantic item macro calls from defrustmacro metadata" do
      defmodule DefrustMacroItemCallCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @type field :: %{
                required(:id) => R.u32(),
                required(:repeated) => R.bool(),
                required(:decode) => R.raw(:DecodeFn)
              }

        @spec build(R.slice(R.path(:Field))) :: R.nif_result(R.unit())
        defrust(build(_fields), do: :ok)

        defrustmacro descriptor(
                       fn: name(:ident),
                       env: env(:ident),
                       fields:
                         repeat do
                           field_id(:literal)
                           field_repeated(:literal)
                           field_decode(:ident)
                         end
                     ) do
          @spec name(R.path(:Env, R.lifetime(:a))) :: R.nif_result(R.unit())
          defrust name(_env) do
            build(
              ref(
                array([
                  repeat fields do
                    struct_literal(Field,
                      id: field_id,
                      repeated: field_repeated,
                      decode: field_decode
                    )
                  end
                ])
              )
            )
          end
        end
      end

      call =
        MetaAST.macro_call!(DefrustMacroItemCallCase, :descriptor,
          fn: :decode_user,
          env: :env,
          fields: [
            [field_id: 1, field_repeated: false, field_decode: :decode_name],
            [field_id: 2, field_repeated: true, field_decode: :decode_tags]
          ]
        )

      source =
        [
          MetaAST.macro_item!(DefrustMacroItemCallCase, :descriptor),
          call
        ]
        |> Enum.map_join("\n", &RustQ.Rust.to_fragment/1)

      assert source =~ "macro_rules! descriptor"
      assert source =~ "descriptor!"
      assert source =~ "fn decode_user;"
      assert source =~ "env env;"
      assert source =~ "1, false, decode_name;"
      assert source =~ "2, true, decode_tags;"
      assert RustQ.valid?(source, "defrustmacro_item_call.rs")
    end

    test "semantic defrustmacro item calls support full message field rows" do
      defmodule DefrustMacroFullMessageItemCallCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @type field :: %{
                required(:id) => R.u32(),
                required(:index) => R.usize(),
                required(:repeated) => R.bool(),
                required(:decode) => R.raw(:DecodeFn)
              }

        @spec build(R.slice(R.path(:Field))) :: R.nif_result(R.unit())
        defrust(build(_fields), do: :ok)

        defrustmacro descriptor(
                       fn: name(:ident),
                       fields:
                         repeat do
                           field_id(:literal)
                           field_index(:literal)
                           field_repeated(:literal)
                           field_decode(:ident)
                         end
                     ) do
          @spec name() :: R.nif_result(R.unit())
          defrust name() do
            build(
              ref(
                array([
                  repeat fields do
                    struct_literal(Field,
                      id: field_id,
                      index: field_index,
                      repeated: field_repeated,
                      decode: field_decode
                    )
                  end
                ])
              )
            )
          end
        end
      end

      call =
        MetaAST.macro_call!(DefrustMacroFullMessageItemCallCase, :descriptor,
          fn: :decode_message,
          fields: [
            [field_id: 1, field_index: 1, field_repeated: false, field_decode: :decode_id],
            [field_id: 2, field_index: 2, field_repeated: true, field_decode: :decode_children]
          ]
        )

      source =
        [
          MetaAST.macro_item!(DefrustMacroFullMessageItemCallCase, :descriptor),
          call
        ]
        |> Enum.map_join("\n", &RustQ.Rust.to_fragment/1)

      assert source =~
               "$field_id:literal, $field_index:literal, $field_repeated:literal, $field_decode:ident;"

      assert source =~ "1, 1, false, decode_id;"
      assert source =~ "2, 2, true, decode_children;"
      assert RustQ.valid?(source, "defrustmacro_full_message_item_call.rs")
    end

    test "semantic defrustmacro item calls support one-capture field repetitions" do
      defmodule DefrustMacroOneCaptureItemCallCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @spec build(R.slice(R.u32())) :: R.nif_result(R.unit())
        defrust(build(_fields), do: :ok)

        defrustmacro descriptor(
                       fn: name(:ident),
                       fields:
                         repeat do
                           field_expr(:expr)
                         end
                     ) do
          @spec name() :: R.nif_result(R.unit())
          defrust name() do
            build(
              ref(
                array([
                  repeat fields do
                    field_expr
                  end
                ])
              )
            )
          end
        end
      end

      call =
        MetaAST.macro_call!(DefrustMacroOneCaptureItemCallCase, :descriptor,
          fn: :decode_values,
          fields: [
            [field_expr: "1 + 2"],
            [field_expr: "3 + 4"]
          ]
        )

      source =
        [
          MetaAST.macro_item!(DefrustMacroOneCaptureItemCallCase, :descriptor),
          call
        ]
        |> Enum.map_join("\n", &RustQ.Rust.to_fragment/1)

      assert source =~ "fields [$("
      assert source =~ "1 + 2;"
      assert source =~ "3 + 4;"
      assert RustQ.valid?(source, "defrustmacro_one_capture_item_call.rs")
    end

    test "selects defrustmacro items by name" do
      defmodule DefrustMacroSelectorCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @spec required_field(R.term(), binary()) :: R.nif_result(R.term())
        defrust required_field(term, _name) do
          {:ok, term}
        end

        defrustmacro field(term, name, type: :ty) do
          decode_as!(required_field(term, name), type)
        end
      end

      [field] = MetaAST.macro_items!(DefrustMacroSelectorCase, [:field])
      source = RustQ.Rust.to_fragment(field)

      assert source =~ "macro_rules! field"
      assert source =~ "required_field($term, $name)?.decode::<$type>()?"

      assert_raise ArgumentError, ~r/no defrustmacro item named missing/, fn ->
        MetaAST.macro_item!(DefrustMacroSelectorCase, :missing)
      end
    end

    test "defrustmacro groups with defrustmod functions" do
      defmodule DefrustMacroModuleCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        defrustmod Helpers, as: :helpers do
          defrustmacro identity(value) do
            value
          end

          @spec decode(R.u32()) :: R.u32()
          defrust decode(value) do
            identity!(value)
          end
        end
      end

      source = DefrustMacroModuleCase.__rustq_source__()

      assert source =~ "mod helpers"
      assert source =~ "macro_rules! identity"
      assert source =~ "fn decode(value: u32) -> u32"
      assert source =~ "identity!(value)"
      assert RustQ.valid?(source, "defrustmacro_module.rs")
    end

    test "defrust lowers remote Rust macro calls" do
      defmodule RemoteRustMacroCallCase do
        use RustQ.Meta
        alias RustQ.Type, as: R

        @spec log_value(R.u32()) :: R.nif_result(R.unit())
        defrust log_value(value) do
          Debug.trace!(value)
          :ok
        end
      end

      source = RemoteRustMacroCallCase.__rustq_source__()

      assert source =~ "Debug::trace!(value);"
      assert RustQ.valid?(source, "remote_rust_macro_call.rs")
    end

    test "defrustmacro reports unsupported fragment annotations" do
      quoted =
        quote do
          defmodule UnsupportedDefrustMacroFragmentCase do
            use RustQ.Meta

            defrustmacro ok(value: :pat) do
              value
            end
          end
        end

      assert_raise Diagnostic.Error, ~r/unsupported Rust macro fragment :pat/, fn ->
        Code.compile_quoted(quoted)
      end
    end

    test "defrustmacro reports duplicate macro names" do
      quoted =
        quote do
          defmodule DuplicateDefrustMacroCase do
            use RustQ.Meta

            defrustmacro same(value) do
              value
            end

            defrustmacro same(left, right) do
              left + right
            end
          end
        end

      assert_raise Diagnostic.Error, ~r/duplicate defrustmacro same/, fn ->
        Code.compile_quoted(quoted)
      end
    end

    test "defrustmacro reports duplicate argument names" do
      quoted =
        quote do
          defmodule DuplicateDefrustMacroArgumentCase do
            use RustQ.Meta

            defrustmacro bad(value, value) do
              value
            end
          end
        end

      assert_raise Diagnostic.Error, ~r/duplicate argument value in defrustmacro bad/, fn ->
        Code.compile_quoted(quoted)
      end
    end

    test "defrustmacro reports type macro variables used as expressions" do
      quoted =
        quote do
          defmodule TypeMacroVariableExpressionCase do
            use RustQ.Meta

            defrustmacro bad(type: :ty) do
              type
            end
          end
        end

      assert_raise Diagnostic.Error,
                   ~r/type is a Rust type fragment, but this is an expression position/,
                   fn ->
                     Code.compile_quoted(quoted)
                   end
    end

    test "defrustmacro reports arity mismatches at macro call sites" do
      quoted =
        quote do
          defmodule DefrustMacroArityMismatchCase do
            use RustQ.Meta
            alias RustQ.Type, as: R

            defrustmacro passthrough(value) do
              value
            end

            @spec decode(R.term()) :: R.term()
            defrust decode(term) do
              passthrough!()
            end
          end
        end

      assert_raise Diagnostic.Error, ~r/macro passthrough! expects 1 arguments, got 0/, fn ->
        Code.compile_quoted(quoted)
      end
    end
  end
end
