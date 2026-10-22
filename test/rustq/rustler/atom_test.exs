defmodule RustQ.Rustler.AtomTest do
  use ExUnit.Case, async: true

  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rustler.Atom

  test "builds atom decoders" do
    code =
      "__rq_items!();"
      |> RustQ.render!("atom_decoder.rs",
        splice: [
          items: [
            Atom.decoder(:decode_blend_mode,
              returns: :BlendMode,
              cases: [src_over: "BlendMode::SrcOver", multiply: "BlendMode::Multiply"]
            )
          ]
        ]
      )

    assert code =~ "pub fn decode_blend_mode(value: Atom) -> NifResult<BlendMode>"
    assert code =~ "value if value == atoms::src_over() => Ok(BlendMode::SrcOver)"
    assert code =~ "_ => Err(rustler::Error::BadArg)"
  end

  test "builds atom decoders from native enum descriptors" do
    descriptor = %RustQ.Native.EnumDescriptor{
      name: "SkClipOp",
      enum: %RustQ.Syn.Enum{name: "SkClipOp", variants: ["Difference", "Intersect"]}
    }

    code =
      "__rq_items!();"
      |> RustQ.render!("atom_decoder_descriptor.rs",
        splice: [
          items: [
            Atom.decoder(:decode_clip_op,
              returns: :ClipOp,
              descriptor: descriptor
            )
          ]
        ]
      )

    assert code =~ "pub fn decode_clip_op(value: Atom) -> NifResult<ClipOp>"
    assert code =~ "value if value == atoms::difference() => Ok(ClipOp::Difference)"
    assert code =~ "value if value == atoms::intersect() => Ok(ClipOp::Intersect)"
  end

  test "builds atom decoders with string function and case names" do
    code =
      "__rq_items!();"
      |> RustQ.render!("atom_decoder_strings.rs",
        splice: [
          items: [
            Atom.decoder("decode_fill_rule",
              returns: :FillRule,
              cases: [{"even_odd", "FillRule::EvenOdd"}]
            )
          ]
        ]
      )

    assert code =~ "pub fn decode_fill_rule(value: Atom) -> NifResult<FillRule>"
    assert code =~ "value if value == atoms::even_odd() => Ok(FillRule::EvenOdd)"
  end

  test "builds atom dispatch functions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("atom_dispatch.rs",
        splice: [
          items: [
            Atom.dispatch(:draw_command,
              lifetimes: [:a],
              args: [surface: "&mut Surface", command: "Term<'a>"],
              on: "command.map_get(atoms::op())?.decode::<Atom>()?",
              cases: [
                rect: "draw_rect(surface, command)",
                circle: "draw_circle(surface, command)"
              ]
            )
          ]
        ]
      )

    assert code =~
             "fn draw_command<'a>(surface: &mut Surface, command: Term<'a>) -> NifResult<()>"

    assert code =~ "let value = command.map_get(atoms::op())?.decode::<Atom>()?;"
    assert code =~ "value if value == atoms::rect() => draw_rect(surface, command)"
    assert code =~ "_ => Ok(())"
  end

  test "builds atom dispatch functions from AST expressions" do
    code =
      "__rq_items!();"
      |> RustQ.render!("atom_dispatch_ast.rs",
        splice: [
          items: [
            Atom.dispatch(:draw_command,
              on: A.atom(:op),
              cases: [rect: A.call(:draw_rect)],
              unknown: A.err(A.badarg())
            )
          ]
        ]
      )

    assert code =~ "let value = atoms::op();"
    assert code =~ "value if value == atoms::rect() => draw_rect()"
    assert code =~ "_ => Err(rustler::Error::BadArg)"
  end
end
