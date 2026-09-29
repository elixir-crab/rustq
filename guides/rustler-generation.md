# Generating Rustler Boundaries

This guide is for existing Rustler crates whose domain implementation remains in
Rust. For a new ordinary NIF, start with
[`RustQ.Native` and `defnif`](zero-rust-nifs.md) instead; they derive the crate,
wrapper, codecs, stubs, initialization, build, and loading together.

Use the helpers below when an existing crate intentionally keeps Cargo and
runtime ownership but wants structural generation for repetitive Rustler glue.
For generator architecture and checked output, also read
[Designing RustQ Generators](designing-generators.md) and
[Generating Rust](generating-rust.md).

## Keep one signature source

A handwritten crate can keep domain implementation functions with an `_impl`
suffix:

```rust
fn parse_nif_impl<'a>(env: Env<'a>, source: &str) -> NifResult<Term<'a>> {
    // domain implementation
}
```

Declare only export policy in Elixir:

```elixir
nifs = [
  parse_nif: [],
  compile_nif: [attrs: [A.attr(:allow, [A.path([:clippy, :too_many_arguments])])]]
]

rust "native/my_nif/src/generated_nifs.rs" do
  RustQ.Rustler.Nif.wrappers_from_source(
    "native/my_nif/src/lib.rs",
    nifs,
    schedule: :dirty_cpu
  )
end

generate "lib/my_app/native/generated_stubs.ex" do
  content(
    RustQ.Rustler.Nif.stubs_from_source(
      "native/my_nif/src/lib.rs",
      nifs,
      MyApp.Native.GeneratedStubs
    )
  )
end
```

`RustQ.Syn` reads arguments, returns, lifetimes, and Rustler's injected `Env`
from the Rust source. The same metadata drives Rust wrappers and Elixir stub
arities, so the export manifest does not repeat signatures.

Keep human-facing `@spec`s in the runtime module and install the generated stubs
once:

```elixir
defmodule MyApp.Native do
  @spec parse_nif(String.t()) :: {:ok, map()} | {:error, term()}

  use MyApp.Native.GeneratedStubs
end
```

If the implementation itself can be expressed cleanly as Rusty-Elixir, prefer
`defnif` rather than retaining an `_impl` wrapper merely for appearance.

## Atom registries

Discover atom calls structurally and emit one registry:

```elixir
atoms =
  "native/my_nif/src/*.rs"
  |> Path.wildcard()
  |> Enum.flat_map(fn path ->
    path |> File.read!() |> RustQ.Syn.atom_references!()
  end)
  |> Enum.uniq()
  |> Enum.sort()

rust "native/my_nif/src/generated_atoms.rs" do
  RustQ.Rustler.Atom.declaration(atoms)
end
```

Exclude generated files from discovery. When a schema or manifest introduces
additional keys, derive those keys from that same source so generation reaches a
stable result in one pass. Do not maintain a second handwritten atom registry.

## Term encoders

`RustQ.Rustler.Term.encoder/2` creates a structural `rustler::Encoder`
implementation. Simple fields are atoms; `{key, field}` renames a key:

```elixir
RustQ.Rustler.Term.encoder(:EncodedLocation,
  fields: [:start, {:end_, :end}, :line]
)
```

Lifetime-bearing adapters can declare target lifetimes and structural field
transformations:

```elixir
RustQ.Rustler.Term.encoder(:EncodedError,
  target_lifetimes: [:_],
  fields: [
    :message,
    code: [when_some: true, via: :as_str]
  ]
)
```

Common field operations include:

- `field: [:result, :code]` — nested field path
- `via: :as_str` — zero-argument method before encoding
- `with: :encode_value` — helper called with the environment and value
- `borrow: false` — pass a helper value without adding `&`
- `when_some: true` — omit the entry when an option is `None`
- `optional: [wrap: :EncodedValue]` — wrap `Some`, encode `None` as nil
- `map: [wrap: :EncodedValue]` — wrap collection elements
- `map: [convert: :EncodedValue]` — map through `From`
- `fallback: [...]` — generate a structural fallback chain

These options represent typed operations. If a transformation becomes domain
logic, move it to a named Rust or Rusty-Elixir helper rather than embedding raw
expressions in field metadata.

## Encoders for types from Rust source

Types owned by another crate cannot implement `rustler::Encoder` in yours, and
may not implement `serde::Serialize` either. `Term.encoders_from_source/3` reads
their definitions through `RustQ.Syn` and builds one encoder function per
reachable type, so the Rust source stays the only owner of fields and variants:

```elixir
index = RustQ.Syn.Index.cached_package("my_ir", manifest_path: "native/my_nif/Cargo.toml")
roots = ["BlockIRNode", "OperationNode"]

opts = [
  tag: :kind,
  wrappers: [sequence: [:ArenaVec], pointer: [:ArenaBox]],
  external: [SimpleExpressionNode: :encode_simple_expr],
  types: [SetPropIRNode: [except: [:loc]]]
]

rust "native/my_nif/src/generated_ir_encoders.rs" do
  [
    RustQ.Rustler.Atom.declaration(Term.encoder_atoms_from_source(index, roots, opts)),
    Term.encoders_from_source(index, roots, opts)
  ]
end
```

Each function has the form
`fn encode_set_prop_ir_node<'a>(env: Env<'a>, value: &SetPropIRNode<'_>) -> Term<'a>`.
Structs encode as atom-keyed maps and newtype structs as their field. Unit
variants encode as atoms, tuple variants as their payload, and named variants as
maps. With `:tag`, data-carrying variants also carry the variant atom under that
key. `Option` encodes `None` as `nil`, sequences and sets as lists, and maps as
maps.

The traversal is closed. Every reachable type must be indexed, a wrapper, a
scalar, or mapped in `:external`; otherwise generation fails and lists the
unmapped types. An upstream change therefore appears as a generation error or a
`rustq.gen --check` diff, not as handwritten Rust to update. Names defined in
several sources and generic types are reported the same way.

Tags, key and variant renames, excluded fields, and external helpers are
explicit policy. Keep them in the consumer's generator, not in RustQ.

## Resources, options, and schemas

`RustQ.Rustler.Resource`, `RustQ.Rustler.Opts`, and
`RustQ.Rustler.Schema` provide structural generation for larger existing
surfaces. Use them when a schema is already the source of truth. Do not add a
schema DSL solely to avoid writing a small, clear `@type` used by
`RustQ.Native`.

Prefer one structural owner for fields and variants. Rust declarations, term
codecs, atom keys, and dispatchers should be projections of that owner rather
than parallel tables.

## CI

Check generated output and both language toolchains:

```elixir
ci: [
  "rustq.gen --check",
  "compile --warnings-as-errors",
  "test"
]
```

Also run `cargo fmt --check`, `cargo check`, and `cargo clippy -- -D warnings`
for every generated native crate. Generated-source freshness alone does not
prove that imported Rust metadata and wrappers still compile together.
