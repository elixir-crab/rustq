# RustQ roadmap

Last reviewed 2026-09-30, at 1.0.0-rc.11. The [changelog](CHANGELOG.md) records
what shipped; this file covers where RustQ stands and what comes next.

## Where things stand

RustQ has been on the 1.0.0 release-candidate line since July. The
[compatibility policy](guides/compatibility.md) defines what 1.x will promise,
and the RC line exists to test that contract before it is frozen.

The core pieces are in place:

- Generated Rust is RustQ AST, rendered natively. There is no string fallback,
  and coherence between the schema, the renderer, and the native decoder is
  tested from `AST.Schema.nodes()`.
- `defrust`, `defrustp`, and `defnif` lower Elixir-shaped code to Rust. A golden
  corpus under `test/corpus` covers the lowering, and `mix ci` checks it with
  `rustq.corpus`.
- `RustQ.Native` builds, loads, and stubs a complete NIF crate from Elixir, with
  no checked-in Rust. Crates that keep their own Cargo and release setup can
  still use it with `build: false, load: false`.
- Lowering infers `?`, `&`, and `&mut` from specs and from callable metadata
  read out of Rust sources and Cargo packages. In Skia, explicit `unwrap!` calls
  went from about 190 in June to 9.
- The Rustler helpers generate NIF wrappers and stubs from Rust source, atom
  registries, term codecs, options, and resources. From rc.11, they also build
  term encoders for types read from another crate's source.
- Failures are reported as structured `RustQ.Diagnostic`s, and Reach checks
  architecture and authoring smells.

## Consumers

| Project | RustQ | What it exercises |
| --- | --- | --- |
| oxc_ex | rc.10 | NIF wrappers and stubs from source, term decoders, lint boundary maps with `RustQ.Native` |
| vize_ex | rc.3, moving to rc.11 | NIF wrappers and stubs, `@type` result codecs, encoders generated from `vize_atelier_vapor`'s source |
| skia_ex | rc.3 | `defrust` drawing commands with generated targets |
| folio | rc.6 | Rustler generation |
| figler | rc.3 | `defrust` helpers over scene storage |
| kiwi_codec | rc.3 | `defrust` helpers and Rustler term helpers |

Only oxc_ex is within one release of the current RC.

## Road to 1.0.0

1.0.0 should change nothing but the version number. Cut it when:

1. The consumers above run the latest RC without needing API changes.
2. `Term.encoders_from_source`, new in rc.11, has a second real consumer. Its
   options were shaped by a single project, vize_ex; oxc_ex's lint types are the
   obvious candidate.
3. A few releases in a row contain only fixes.
4. The compatibility policy decides whether it needs an experimental tier.
   Today every documented API is covered in full, so anything shipped in 1.0.0
   is frozen for 1.x.
5. The identifier and typespec matrices below pass.

## Before 1.0.0

**Identifier and typespec matrices.** rc.11 fixed three bugs in surfaces that
had simply never been exercised. Rust keywords failed to render as field
accesses, as struct fields, and as macro arguments, and a literal atom in a
typespec produced a Rust type named after the atom. Instead of waiting for the
next one, add two generated tests: one that renders every identifier-bearing AST
position with every Rust keyword, and one over the typespec forms that the
codecs accept.

**Consumer upgrades.** Move the consumers to rc.11 and note any API friction
here.

## 1.x

**Remaining propagation inference.** Skia's last nine explicit `unwrap!` calls
fall into two groups. Six are the macro-generated `CommandDomain` entrypoint
decodes (`decode_args`, `decode_opts`, and the generated options decoders). The
other three are in text commands, where the call is a setter argument or a
`case` arm (`decode_text_decoration_mode`, `paragraph_paint_y`). Each needs a
corpus fixture before the inference changes. Under the compatibility policy,
new inference may only apply where RustQ currently requires the explicit form;
programs that already compile must keep producing equivalent Rust.

**Borrow and `mut` intent.** Carry `&mut` from `Syn` argument types into lowered
bindings instead of relying on heuristics. This is not a borrow checker, only
"this argument is `&mut`, so the binding is a mutable reference".

**Bindings from `Syn`.** `RustQ.Binding.Callable` already normalizes Rust
functions and methods for lowering. What remains is generating Rusty-Elixir
wrappers and lowering targets from those callables, the reverse mapping from
specs to `Syn` types, and better fidelity for generics and lifetimes.

**Codecs from Rust source.** Decoders to mirror `Term.encoders_from_source`,
then move oxc_ex's lint types and vize_ex's remaining handwritten shapes onto
them.

**Multi-file generation for existing crates.** `RustQ.Native` covers crates
RustQ owns. Crates that keep Cargo ownership still hand-roll their target lists,
as Skia does with `generated_targets/0`. `rustq.exs` should be able to declare
several outputs and the `mod` declarations that tie them together.

**Module composition.** `defrustimpl` covers inherent and trait impls. `pub use`
re-exports and grouping impls across modules are still open.

## Deliberate limits

Some explicit borrows and adapters are required by the Rust API rather than
missing inference, and should not be "cleaned up":

- Stored references, such as Skia's `SaveLayerRec::bounds(&'a Rect)`, need a
  borrow that outlives the call.
- Indexed storage, such as Figler's `ref(index(scene.nodes, node_index))`, is
  borrowed to avoid moving out of the collection.
- Slice and option-reference parameters in Skia's gradient, path effect, and
  shader APIs need exact adapter shapes.

Inference work should target the open cases above, with corpus coverage first.
