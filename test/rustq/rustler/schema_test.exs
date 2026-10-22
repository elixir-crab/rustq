defmodule RustQ.Rustler.SchemaTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rustler.Schema

  defmodule ContentSchema do
    use RustQ.Rustler.Schema

    schema Folio.Content do
      default_attrs([A.allow_attr(:dead_code)])

      node Text do
        field(:text, :String)
        field(:size, {:option, :String})
      end

      node Space do
      end

      node Paragraph do
        field(:body, {:vec, Content})
      end

      tagged_enum Content do
        variants(:all)
        unknown(:unknown_content_variant)
      end
    end
  end

  test "exposes normalized schema data" do
    schema = ContentSchema.schema()

    assert schema.module_prefix == Folio.Content
    assert schema.rust_prefix == "Ex"
    assert schema.tag_field == :__struct__
    assert [%AST.Attribute{path: [:allow], args: [:dead_code]}] = schema.default_attrs
    assert schema.type_aliases == []
    assert {:Text, [text: :String, size: {:option, :String}]} not in schema.nodes

    assert {:Text, [{:text, :String, []}, {:size, {:option, :String}, []}], []} in schema.nodes
  end

  defmodule OverrideSchema do
    use RustQ.Rustler.Schema

    schema Folio.Content do
      node Enum, rust: :ExEnum, module: Folio.Content.EnumList do
        field(:children, {:vec, Content})
      end

      node TermItem do
        field(:term, {:vec, Content})
      end

      tagged_enum Content do
        variants([:Enum, :TermItem])
      end
    end
  end

  test "generates Rustler structs and tagged enum" do
    code =
      "__rq_items!();"
      |> RustQ.render!("schema.rs", splice: [items: ContentSchema.rust_items()])

    assert code =~ "#[allow(dead_code)]"
    assert code =~ ~S/#[module = "Folio.Content.Text"]/
    assert code =~ "pub struct ExText"
    assert code =~ "pub size: Option<String>"
    assert code =~ "pub struct ExParagraph"
    assert code =~ "pub body: Vec<ExContent>"
    assert code =~ "pub enum ExContent"
    assert code =~ "Text(ExText)"
    assert code =~ ~S/"Elixir.Folio.Content.Text"/
    assert code =~ "Ok(ExContent::Text(rustler::Decoder::decode(term)?))"
    assert code =~ ~S/Err(rustler::Error::RaiseAtom("unknown_content_variant"))/
  end

  test "builds structural declaration and shorthand field splices" do
    code =
      RustQ.render!(
        """
        struct Projection {
            __rq_fields: (),
        }

        fn projection(name: String, visible: bool) -> Projection {
            Projection {
                __rq_build_fields: (),
            }
        }
        """,
        "projection.rs",
        splice: [
          fields: Schema.struct_fields(name: :String, visible: :bool),
          build_fields: Schema.shorthand_fields([:name, :visible])
        ]
      )

    assert code =~ "name: String"
    assert code =~ "visible: bool"
    assert code =~ "Projection { name, visible }"
  end

  test "raises structured diagnostics for raw tagged enum attrs" do
    defmodule InvalidAttrSchema do
      use RustQ.Rustler.Schema

      schema Folio.Content, default_attrs: ["allow(dead_code)"] do
        node Text do
          field(:text, :String)
        end

        tagged_enum Content do
          variants(:all)
        end
      end
    end

    assert_raise RustQ.Diagnostic.Error, ~r/render invalid_tagged_enum_attr/, fn ->
      InvalidAttrSchema.rust_items()
    end
  end

  test "supports node Rust and module overrides" do
    code =
      "__rq_items!();"
      |> RustQ.render!("schema.rs", splice: [items: OverrideSchema.rust_items()])

    assert code =~ ~S/#[module = "Folio.Content.EnumList"]/
    assert code =~ "pub struct ExEnum"
    assert code =~ "pub children: Vec<ExContent>"
    assert code =~ "Enum(ExEnum)"

    assert code =~ ~S/"Elixir.Folio.Content.EnumList" =>/
    assert code =~ "Ok(ExContent::Enum(rustler::Decoder::decode(term)?))"
    assert code =~ ~S/"Elixir.Folio.Content.TermItem" =>/
    assert code =~ "Ok(ExContent::TermItem(rustler::Decoder::decode(term)?))"
  end
end
