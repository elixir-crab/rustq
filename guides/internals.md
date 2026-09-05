# RustQ internal structure

This is a maintainer map, not an additional public API contract. Public stability
is defined in [compatibility.md](compatibility.md).

## Ownership

| Area | Responsibility |
| --- | --- |
| `RustQ`, `Template`, `Splice`, `Generated`, `Config` | Template/rendering entrypoints, generation plans, and checked output |
| `Meta` | Rusty-Elixir macro frontend and compilation orchestration |
| `Meta.AST` | Public compiled-item access and function/type construction |
| `Meta.Type`, `Spec`, `Meta.Typing`, `Meta.Inference` | Type representation, spec conversion, expression synthesis, and coercion decisions |
| `Meta.Lower` and `Meta.Lower.*` | Translation to Rust AST; evaluation order and expected-type propagation |
| `Binding` | Callable signatures and lookup indexes, populated from structural sources |
| `Syn`, `Syn.Index`, `Cargo` | External Rust parsing, package discovery, and metadata indexing |
| `Rust.AST` and its builders | Rust syntax model and structural composition |
| `Rust`, `Rust.AST.Render` | Rendering boundary, with native syntax construction where appropriate |
| `Rustler` | Reusable Rustler bridge-generation APIs |
| `Native` | Public zero-handwritten-Rust NIF authoring facade |
| `Native.Options` | Native option vocabulary, defaults, and validation |
| `Native.ABI` | Boundary codec/resource preparation and internal result-call routing |
| `Native.Manifest` | Cargo manifest policy as data, serialized by the TOML library |
| `Native.Build` | Cargo invocation, artifact installation, and loader generation |
| `Codegen` | RustQ's own native AST-decoder generator; not a second consumer compiler |
| `Reach` | Architecture and authoring checks |
| `SourceFingerprint` | Shared content identity for source-backed caches |

`Native.Ref`, `Native.Descriptor`, and `Native.EnumDescriptor` are existing
public metadata APIs. Their placement predates the NIF authoring implementation;
keep their names stable rather than moving them for visual symmetry.
`Native.Nif` is the private loader for RustQ's own native support, not the code
that builds a consumer's generated crate.

## Boundaries to preserve

- The macro frontend supplies resolved aliases and callable metadata to lowering.
  Lowering must not discover packages or run Cargo while processing expressions.
- Expected types must cross branch and closure boundaries explicitly. The
  enclosing function's return type is not the mapper's return type.
- ABI adaptation belongs at the exported boundary. Internal native calls retain
  their native signatures; do not globally replace result constructors.
- Source and package caches must observe content changes. Derived callable caches
  must not bypass their source's freshness checks.
- AST construction is separate from serialization. Use RustQ for Rust and a TOML
  encoder for manifests, not interpolated function bodies or configuration syntax.
- Resource ownership, synchronization, scheduling, and numeric overflow policy
  remain explicit native decisions.

## Bootstrap and dogfooding

The checked-in `native/rustq_nif/src/generated_ast.rs` is a bootstrap input.
RustQ first compiles that input, then uses its public AST and Rusty-Elixir APIs
under `lib/rustq/codegen/` to regenerate it. Consumers do not need to regenerate
RustQ's native support to compile the package.

After changing self-hosted generation, verify:

1. Clean Elixir compilation against checked-in native support.
2. `mix rustq.gen`.
3. Rebuild the native crate and recompile Elixir in a fresh Mix invocation.
4. `mix rustq.gen --check` and compare the generated file with step 2.
5. `mix ci`, including packaged consumers.

A clean Elixir build with existing Cargo caches is useful, but is not equivalent
to an isolated no-cache bootstrap. Keep that distinction in validation reports.

The native `syn` parsing, traversal, and token conversion layer is intentional.
Move repetitive boundary logic to Rusty-Elixir where that simplifies its source;
do not port clear domain Rust merely to increase generated-code counts.

## Further extraction criteria

`Meta.Lower`, `Meta.Type`, and `Syn` are substantial modules. Size alone is not a
reason to divide them. Extract a cohesive operation only when its inputs and
outputs can be named and tested independently. Prefer branch/closure lowering,
type conversion, or source-query responsibilities over generic `Utils` modules.

Keep focused tests parallel to their owning modules under `test/rustq/`.
Cross-package runtime behavior belongs in `integration/` fixtures driven through
`test/support/`; source grep tests are not architecture enforcement.
