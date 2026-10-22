defmodule RustQ.Rustler.ResourceTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rustler.{Atom, Opts, Resource}

  test "builds resource helper boilerplate" do
    code =
      "__rq_items!();"
      |> RustQ.render!("resource.rs",
        splice: [
          items: [
            Resource.type_alias(:Document),
            Resource.decoder(:Document),
            Resource.init(:Document)
          ]
        ]
      )

    assert Resource.arc_type(:Document)
           |> Rust.render_type()
           |> IO.iodata_to_binary() == "ResourceArc<Document>"

    assert code =~ "type DocumentResource = ResourceArc<Document>;"

    assert code =~
             "fn decode_document_resource<'a>(term: Term<'a>) -> NifResult<ResourceArc<Document>>"

    assert code =~ "rustler::resource! {"
    assert code =~ "Document, env,"
  end

  test "builds resource boilerplate" do
    code =
      "__rq_items!();"
      |> RustQ.render!("resource.rs",
        splice: [
          items: Resource.items(:EncodedImage, fields: [bytes: {:vec, :u8}])
        ]
      )

    assert code =~ "struct EncodedImage"
    assert code =~ "pub bytes: Vec<u8>"
    assert code =~ "#[rustler::resource_impl]"
    assert code =~ "impl rustler::Resource for EncodedImage"
  end

  test "builds resource handle boilerplate" do
    code =
      "__rq_items!();"
      |> RustQ.render!("resource_handle.rs",
        splice: [
          items:
            Resource.handle_items(:EncodedImage,
              fields: [bytes: "Vec<u8>"],
              handle_field: :ref
            )
        ]
      )

    assert code =~ "struct EncodedImage"
    assert code =~ "pub bytes: Vec<u8>"
    assert code =~ "impl rustler::Resource for EncodedImage"
    assert code =~ "fn decode_encoded_image_handle<'a>"
    assert code =~ "term: Term<'a>"
    assert code =~ ~S/Atom::from_bytes(term.get_env(), b"ref")?/
    assert code =~ ".decode::<ResourceArc<EncodedImage>>()"
  end

  test "builds resource handles with custom decoder and field" do
    code =
      "__rq_items!();"
      |> RustQ.render!("resource_handle.rs",
        splice: [
          items:
            Resource.handle_items(:Session,
              fields: [id: :u64],
              handle_field: "handle",
              decoder: :decode_session_ref
            )
        ]
      )

    assert code =~ "fn decode_session_ref<'a>"
    assert code =~ ~S/Atom::from_bytes(term.get_env(), b"handle")?/
    assert code =~ ".decode::<ResourceArc<Session>>()"
  end

  test "builds option struct decoders" do
    alias RustQ.Rust.AST.Builder, as: A
    alias RustQ.Rustler.Decode, as: R

    code =
      "__rq_items!();"
      |> RustQ.render!("opts.rs",
        splice: [
          items:
            Opts.decoder(:RectOpts,
              lifetime: :a,
              fields: [
                x: [type: :f32, decode: R.opt_decode(:opt_f32, :opts, :x)],
                mode: [
                  type: :Atom,
                  decode: R.required_opt_decode(:opt_atom_option, :opts, :mode)
                ],
                count: [
                  type: {:option, :i64},
                  decode: R.optional_term_decode(:opts, :count, :i64)
                ],
                fill: [
                  type: {:option, "Term<'a>"},
                  decode: A.call(:opt_term, [:opts, A.atom(:fill)])
                ]
              ]
            )
        ]
      )

    assert code =~ "pub struct RectOpts<'a>"
    assert code =~ "pub x: f32"
    assert code =~ "pub mode: Atom"
    assert code =~ "pub count: Option<i64>"
    assert code =~ "pub fill: Option<Term<'a>>"

    assert code =~
             "pub fn decode_rect_opts<'a>(opts: &[(Atom, Term<'a>)]) -> NifResult<RectOpts<'a>>"

    assert code =~ "x: opt_f32(opts, atoms::x())?"
    assert code =~ "mode: opt_atom_option(opts, atoms::mode())?.ok_or(rustler::Error::BadArg)?"
    assert code =~ "match opt_term(opts, atoms::count())"
    assert code =~ "Some(term) => Some(term.decode::<i64>()?)"
    assert code =~ "None => None"
    assert code =~ "fill: opt_term(opts, atoms::fill())"
    assert code =~ "_phantom: std::marker::PhantomData"
  end

  test "builds option struct decoders from Meta type fields" do
    code =
      "__rq_items!();"
      |> RustQ.render!("typed_opts.rs",
        splice: [
          items:
            Opts.decoder(:TypedOpts,
              lifetime: :a,
              fields: [
                x: [type: RustQ.Spec.type(quote(do: RustQ.Type.f32())), required: true],
                mode: [type: RustQ.Spec.type(quote(do: RustQ.Type.enum(:mode))), required: true],
                label: [type: RustQ.Spec.type(quote(do: String.t()))],
                paint: [type: RustQ.Spec.type(quote(do: Skia.Paint.t()))]
              ]
            )
        ]
      )

    assert code =~ "pub x: f32"
    assert code =~ "pub mode: Atom"
    assert code =~ "pub label: Option<String>"
    assert code =~ "pub paint: Option<Term<'a>>"
    assert code =~ "x: opt_f32(opts, atoms::x())?"
    assert code =~ "mode: opt_atom_option(opts, atoms::mode())?.ok_or(rustler::Error::BadArg)?"
    assert code =~ "match opt_term(opts, atoms::label())"
    assert code =~ "Some(term) => Some(term.decode::<String>()?)"
    assert code =~ "paint: opt_term(opts, atoms::paint())"
  end

  test "builds bare atoms blocks" do
    code =
      RustQ.render!("__rq_items!();", "atoms.rs",
        splice: [items: [Atom.declaration([:ok], module: false)]]
      )

    assert code =~ "rustler::atoms!"
    refute code =~ "mod atoms"
  end
end
