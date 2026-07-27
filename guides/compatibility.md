# RustQ 1.x compatibility policy

This document defines RustQ's 1.x compatibility contract. The `1.0.0-rc`
release line validates it before the stable release.

This is a stability policy, not an authoring guide. Start with
[Using RustQ Well](using-rustq-well.md),
[Zero-handwritten-Rust NIFs](zero-rust-nifs.md), or
[Generating Rust](generating-rust.md) for usage.

RustQ connects three surfaces: Elixir authoring APIs, structural RustQ AST, and
generated Rust. Compatibility has to describe all three rather than treating a
successful Elixir compilation as the entire contract.

## Public API

An Elixir module, function, macro, struct, or type is public when it is included
in RustQ's generated HexDocs and has public documentation. Its documented
arguments, return values, options, and examples are part of the 1.x contract.

This includes the documented surfaces under:

- `RustQ`, `RustQ.Config`, `RustQ.Generated`, and template/splice APIs
- `RustQ.Native`, including documented `defnif`/`defrustp` behavior, external
  crate preparation, `nif_env/0`, and native options
- `RustQ.Test` and its documented composable ExUnit helpers
- `RustQ.Meta`, `RustQ.Meta.AST`, `RustQ.Meta.Type`, `RustQ.Spec`,
  `RustQ.Type`, and documented `RustQ.Binding` metadata modules
- `RustQ.Rust` and the documented `RustQ.Rust.AST` nodes and builders
- `RustQ.Rustler` feature modules
- `RustQ.Syn`, `RustQ.Cargo`, and documented native metadata values
- `RustQ.Diagnostic` data and the documented Reach checks
- generated `RustQ.Meta` accessors documented by `RustQ.Meta`, including
  `__rustq_items__/0`, `__rustq_source__/0`, and `__rustq_type_items__/0`; for
  structural metadata, prefer the focused `RustQ.Meta.AST` selectors such as
  `functions/1`, `function!/2`, `type_item!/2`, and `impl!/3`

A module is not public merely because it is compiled into the package or can be
addressed by name. Modules with `@moduledoc false`, functions with `@doc false`,
and implementation namespaces such as native NIF decoders, AST rendering,
lowering, inference, cache, and schema-introspection internals are not stable
APIs. In particular, consumers must not call the hidden AST renderer, native
NIF implementation, lowerer, inference engine, or cache implementation.

`SKILL.md` is part of the shipped compatibility documentation. Agents and
maintainers should follow its public/private boundary and authoring ladder just
as they follow the API reference. Guides may be reorganized and clarified in
patch releases; documented public behavior remains governed by this policy.

## Semantic versioning

RustQ 1.x follows these rules:

### Patch releases

Patch releases may:

- fix incorrect lowering, inference, diagnostics, parsing, or rendering
- make previously invalid generated Rust compile
- reduce false-positive Reach findings
- change generated formatting, local variable names, or other semantically
  equivalent source details
- update documentation, tests, and supported patch-level dependencies

Patch releases do not intentionally remove a documented API, reject a
previously documented valid input, or change the documented meaning of a valid
Rusty-Elixir program.

### Minor releases

Minor releases may:

- add documented functions, options, AST nodes, lowering forms, metadata, or
  Reach checks
- add fields with defaults to public option-like structs
- recognize more Rust syntax or infer more cases that were previously rejected
- emit new diagnostics for newly checked invalid input

New Reach checks and changes that can introduce findings in strict consumers
belong in a minor release and must be documented.

### Major releases

A major release is required to:

- remove or rename documented modules, functions, options, AST nodes, fields, or
  diagnostic fields
- change the meaning of an already documented Rusty-Elixir form
- make a documented valid input invalid without treating the old behavior as a
  correctness or safety defect
- change a public AST node's category or reinterpret an existing field
- change the minimum Elixir version outside the currently declared compatible
  series

Security and soundness fixes may override this classification when preserving
old behavior would be unsafe. Such exceptions must be called out explicitly.

## Rusty-Elixir lowering

Documented Rusty-Elixir forms are source-level API. Accepting an additional form
is additive. Changing how an existing documented form behaves is breaking unless
the old output was invalid Rust or contradicted its documented semantics.

Inference is guaranteed semantically, not by a promise about every intermediate
internal type. A supported program should keep producing equivalent Rust.
Diagnostics for unsupported or ambiguous programs may become more precise.

The documented `RustQ.Diagnostic` fields remain available throughout 1.x.
Diagnostic prose and snippets may improve in patch releases. Consumers that need
machine-readable behavior should match `phase` and `kind`, not the complete
human-readable `message`.

## RustQ AST

RustQ AST is the sole structural representation for generated Rust. Public AST
struct names, categories, fields, and documented builder behavior are stable in
1.x.

Adding a new AST node is additive. Adding a defaulted field is additive, but
consumers should avoid exhaustive assumptions over internal schema enumeration
unless they intentionally want to react to new nodes. Removing, renaming, or
reclassifying a node requires a major release.

Every public AST node must continue to have behavioral native rendering
coverage. RustQ will not silently introduce a second fallback renderer.

## Generated Rust

RustQ guarantees that generation is deterministic for the same RustQ version,
inputs, relevant configuration, and formatter toolchain. It does not guarantee
byte-identical generated Rust across RustQ releases or different `rustfmt`
versions.

Patch releases may change whitespace, spans, local identifiers, and equivalent
expression structure. Checked-in generated files must therefore be regenerated
when RustQ is updated. `mix rustq.gen --check` is the supported freshness gate.

A patch release must not intentionally change the runtime meaning or public Rust
signature produced from an already documented valid input. Fixing invalid Rust,
unsound output, or output that contradicted the documented input is allowed and
must have behavioral coverage.

## Reach checks

RustQ's Reach check modules and finding kinds are public. Consumers own
strictness, ignored paths, and baselines in `.reach.exs`; the portable checks do
not contain consumer-specific exemptions.

A patch may remove false positives without renaming a finding kind. A new check,
a new finding kind, or a material expansion that can fail a previously clean
strict consumer belongs in a minor release. Removing or renaming a documented
check or kind requires a major release.

## Toolchains and dependencies

The supported Elixir range is the range declared in `mix.exs`. RustQ requires a
working stable Rust toolchain and Cargo wherever its native compiler or codegen
tasks run. Generated formatting can vary with `rustfmt`; pin the Rust toolchain
when exact checked-in output matters.

RustQ may widen dependency requirements in minor or patch releases. Narrowing a
requirement in a way that excludes a previously supported dependency line, or
raising the minimum Elixir series, follows the breaking-change rules above.

## Deprecation and removal

A documented API targeted for removal should first be deprecated in a minor
release with a direct migration path. It remains available for the rest of the
1.x line unless retaining it would be unsafe. Removal occurs in the next major
release.

RustQ does not add compatibility aliases for hidden implementation APIs.
Consumers using hidden modules must migrate to the documented public surface.

## Release validation

Before a stable release, RustQ validates:

1. the full RustQ CI and native crate
2. the packaged Hex artifact, not only the source checkout
3. the external public-consumer fixture using only documented APIs
4. checked-in generation and native compilation
5. owned consumers without local path dependencies

The external fixture is intentionally small. Its job is to catch missing package
files, accidental hidden-module dependencies, public API drift, stale generation,
and native compilation failures before publication.
