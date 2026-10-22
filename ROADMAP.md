# RustQ roadmap

Last reviewed 2026-10-23, at 1.0.0-rc.13. The [changelog](CHANGELOG.md) records
what shipped; this file covers where RustQ stands and what comes next.

## Where things stand

RustQ has been on the 1.0.0 release-candidate line since July. The
[compatibility policy](guides/compatibility.md) defines what 1.x will promise,
and the RC line exists to test that contract before it is frozen. 1.0.0 was
published on 2026-10-22 and reverted within the hour, because the conditions
below did not hold yet; the same work shipped as rc.12.

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
| figler | rc.3, moving to rc.12 | `defrust` helpers over scene storage, an effective graph interpreted natively |
| kiwi_codec | rc.3, moving to rc.12 | `defrust` helpers, Rustler term helpers, and native Kiwi records |

oxc_ex is within two releases of the current RC; kiwi_codec and figler are
moving to it.

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
5. The identifier and typespec matrices pass. They do since rc.13, which fixed
   what they found.

## Before 1.0.0

**Consumer upgrades.** Move the consumers to the latest RC and note any API
friction here.

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

**One contract for precompiled NIFs.** Crates that keep their own Cargo and
release setup, such as vize_ex and oxc_ex, write each NIF's contract down
several times: the Rust `*_nif_impl` signatures, the `@spec`s in the
RustlerPrecompiled module, the `@type`s in the codegen module that derive the
Rust structs, and the public `@type`s describing the same maps. Nothing checks
that they agree. The codegen module should be the one source, with both sides
generated, committed, and checked by `mix rustq.gen --check`:

- Elixir stubs with specs from `defnif` in `build: false, load: false` mode, as
  `RustQ.Native.stubs(module, as: ...)` mirroring `Nif.stubs_from_source/4`.
  Specs take their Elixir-facing form: `R.u32` becomes `non_neg_integer()`,
  `R.nif_result(t)` becomes `t`, and `nif_env()` is dropped. One table maps
  `R.*` types to Elixir types for specs and public types alike.
- Wrappers that delegate to handwritten `*_impl` functions, with a diagnostic at
  generation time when a wrapper and its `*_impl` signature in `rust_sources`
  disagree, instead of a Cargo error later.
- Public types from the codegen module's `@type`s and `@typedoc`s, as
  `RustQ.Native.types_source(module, as: ...)`, so the library references
  `Vize.Types.sfc_result()` instead of restating the map.

Types flow one way, from the codegen module outward. Deriving Rust from
documented `@type`s in `lib/` was considered and set aside: `non_neg_integer()`
or `String.t()` doesn't say which Rust type to use, `lib/` can't use `R.*`
markers because Hex source builds have no RustQ, and the gaps would move into a
separate table of overrides. All three are additive. Prove them on vize_ex,
replacing `vapor_split_nif` and `compile_sfc_nif`'s positional booleans with a
typed options map, and on oxc_ex's lint types.

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
