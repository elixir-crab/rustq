# Using RustQ Well

RustQ makes Elixir↔Rust bridge generation readable. The goal is not to move Rust
string concatenation from `.rs` files into `.ex` files; it is to let Elixir act
as a typed, semantic authoring and metaprogramming layer for Rust.

This is the canonical best-practices guide. Task-specific mechanics live in:

- [Zero-handwritten-Rust NIFs](zero-rust-nifs.md)
- [Generating Rust](generating-rust.md)
- [Generating Rustler Boundaries](rustler-generation.md)
- [Designing RustQ Generators](designing-generators.md)

RustQ also ships [`SKILL.md`](../SKILL.md), the operational version of this
guide for coding agents.

## The authoring ladder

Before writing generated Rust as text, use the highest honest layer:

1. `defnif` for a public NIF implemented as Rusty-Elixir.
2. `defrust` or `defrustp` for generated Rust helpers.
3. Ordinary Elixir functions, macros, `quote`, and `unquote` for composition.
4. Rust source, Cargo package, typespec, and schema metadata for inference.
5. RustQ AST for Rust-only structure.
6. Parseable `.rs` templates for substantial handwritten Rust around generated
   regions.
7. Tiny raw token escapes only when RustQ has no semantic representation.

Do not skip directly from Elixir to strings. A missing AST node or lowering form
is usually a RustQ capability gap, not a reason to create a private string DSL.

## Start with the owner of the native crate

Use `RustQ.Native` when RustQ should generate, build, and load the crate:

```elixir
defmodule MyApp.Native do
  use RustQ.Native

  @spec sum([float()]) :: float()
  defnif sum(values), do: Enum.sum(values)
end
```

Use `RustQ.Meta` when RustQ generates helpers or items for a crate owned
elsewhere:

```elixir
defmodule MyApp.Generated do
  use RustQ.Meta,
    rust_sources: ["native/my_app/src/helpers.rs"]

  alias RustQ.Type, as: R

  @spec decode(R.term()) :: R.nif_result(Value.t())
  defrust decode(term), do: decode_value(term)
end
```

Do not make RustQ seize Cargo, loading, initialization, or release ownership from
an existing or precompiled crate. Use `RustQ.Native, build: false, load: false`
when that crate only needs ABI-prepared items.

## Specs are the source of truth

Write a real `@spec` for every `defnif` and `defrust`. RustQ uses it for the Rust
signature, expected return type, propagation, borrowing, and NIF boundary.

Prefer ordinary Elixir and remote types:

```elixir
@spec draw(
        R.ref(SkiaSafe.Canvas.t()),
        GeneratedOpts.CircleOpts.t(R.lifetime(:a)),
        R.slice({R.atom(), R.term()})
      ) :: R.nif_result(R.unit())
```

Use `RustQ.Type` only for Rust-specific precision such as references, fixed-width
numbers, lifetimes, `NifResult`, slices, options, results, vectors, terms, and
resources. `R.raw/1` and `R.path/1,2` are low-level escapes, not the default way
to spell an external Rust type.

Use ordinary `@type` declarations for RustQ-owned shapes. Maps and Elixir
structs can derive Rust structs and directional codecs; atom unions can derive
unit enums; unions of structural types can derive tagged enums.

## Let RustQ infer

RustQ can infer `?`, `&`, and `&mut` when it knows callable signatures and
expected types:

```elixir
@spec decode_color(R.term()) :: R.nif_result(Color.t())
defrust decode_color(term) do
  value = decode_as!(term, R.u32())
  {:ok, Color.from_argb(255, 0, 0, value)}
end

@spec draw(R.ref(Canvas.t()), R.term()) :: R.nif_result(R.unit())
defrust draw(canvas, term) do
  canvas.draw_color(decode_color(term))
  :ok
end
```

Before adding `unwrap!`, `ref`, `mut_ref`, or a wrapper function, ask whether
RustQ can see the called function or method. Callable metadata can come from:

- local `@spec`s
- `callable_modules`
- configured `rust_sources`
- configured `rust_packages`
- known receiver and expected argument types

Use `unwrap!` only to force propagation when the metadata cannot yet express the
shape. Use `ok_or!` for an intentional `Option<T>` to `Result`/`NifResult`
boundary. Explicit borrowing helpers remain useful when the borrow itself is
part of the intended semantics.

## Read Rust instead of shadowing it

If Rust owns a function, method, or type, import its metadata rather than
maintaining a parallel Elixir registry:

```elixir
use RustQ.Meta,
  rust_sources: ["native/my_app/src/helpers.rs"],
  rust_packages: [{"skia-safe", manifest_path: "native/my_app/Cargo.toml"}],
  callable_modules: [MyApp.GeneratedEnums]
```

This is especially important for fallible methods and generic adapters such as
`impl AsRef<T>`, `impl Into<T>`, and `impl IntoIterator<Item = T>`. A trivial
wrapper created only because callable metadata is missing is technical debt.
Expose the real Rust definition or improve RustQ's inference instead.

## Keep Rusty-Elixir functional

Write implementation logic as valid Elixir-shaped control flow:

- pattern matching and multiple clauses
- recursion for small state machines
- `case`, `if`, `unless`, `cond`, and `with`
- comprehensions and reducers for repeated work
- ordinary local and remote calls

Prefer recursion over low-level loops:

```elixir
@spec skip_many(R.mut_ref(Decoder.t()), R.u32()) :: R.nif_result(R.unit())
defrust skip_many(_decoder, 0), do: :ok

defrust skip_many(decoder, remaining) do
  skip_one(decoder)
  skip_many(decoder, remaining - 1)
end
```

RustQ has internal representations for `loop`, `break`, `continue`, and early
return because its Rust backend needs them. They are not the preferred product
language. Use `return!` only when a low-level early exit is genuinely clearer.

RustQ deliberately rejects Elixir operations whose semantics cannot be
preserved. Do not replace a rejected grapheme, dynamic map, range, process, IO,
or protocol operation with a vaguely similar Rust method. Put the semantic
choice behind an explicit adapter.

## Compose with ordinary Elixir

Ordinary Elixir metaprogramming is the main composition layer:

```elixir
defmacro with_saved_canvas(do: body) do
  quote do
    var!(canvas).save()
    unquote(body)
    var!(canvas).restore()
  end
end
```

RustQ expands normal macros before lowering. Use helper functions returning
quoted Rusty-Elixir, `defmacro`, `quote`, `unquote`, and `unquote_splicing`
before inventing a RustQ-specific syntax.

`defrustmacro` solves a narrower problem: it emits a compact Rust
`macro_rules!` helper when the generated Rust itself would otherwise repeat a
small pattern. Keep it small and keep its body Rusty-Elixir. Do not use it as a
second general-purpose language.

## Put Rust methods in `defrustimpl`

When Rusty-Elixir functions belong to a Rust implementation, group them with
`defrustimpl` rather than retrieving and rewriting function ASTs. The first
argument remains an ordinary Elixir variable. Type it with `R.ref/1` for
`&self` or `R.mut_ref/1` for `&mut self`:

```elixir
defrustimpl ComponentRegistry, vis: :crate do
  @spec input_mut(R.mut_ref(R.path(:ComponentRegistry)), R.str()) ::
          R.option(R.mut_ref(R.path(:ComponentInput)))
  defrust input_mut(self, id) do
    self.entries.get_mut(ref(id))
  end
end
```

Trait implementations use `:for`:

```elixir
defrustimpl Display, for: Widget do
  @spec display(R.ref(R.path(:Widget))) :: R.str()
  defrust display(self), do: self.label.as_str()
end
```

Implementation metadata can use `:vis`, `:attrs`, and `:lifetimes`.

## Use AST for Rust-only structure

Rust declarations, attributes, unsafe blocks, and other Rust-only structures
belong in RustQ AST:

```elixir
alias RustQ.Rust.AST.Builder, as: A

A.const(:MAX_FIELDS, :usize, A.lit(128), vis: :pub)
```

Generators can access compiled function structure through
`RustQ.Meta.AST.functions/1` and `RustQ.Meta.AST.function!/2`. Do not call the
hidden `__rustq_asts__/0` accessor or hidden renderer directly.

Use `expr!`, `pat!`, `stmt!`, and `arm!` when a semantic Rust-shaped value is
needed inside Rusty-Elixir. Use `raw_expr!`, `raw_pat!`, `raw_stmt!`, and
`raw_arm!` only as explicit, local token escapes.

See [Generating Rust](generating-rust.md) for templates, builders, splices,
checked generation, and fragment validation.

## Keep real policy explicit

Inference should remove duplication, not decisions. Keep these visible:

- Cargo dependency versions and features
- normal, dirty CPU, or dirty IO scheduling
- resource ownership, synchronization, and thread safety
- blocking and unsafe operations
- lossy conversions and custom adapters
- platform linking and precompiled release targets

RustQ should never infer safety or deployment policy from a function name or
body shape.

## Avoid these failure modes

### String-built functions

Do not assemble complete functions from interpolated Rust fragments. Use
Rusty-Elixir, AST, or a parseable template.

### Duplicate signature registries

Do not copy names, arities, argument types, lifetimes, and returns into a second
manifest when RustQ can derive them from specs, source, schemas, or AST.

### Wrappers that only satisfy the generator

Keep wrappers that encode real bridge semantics or stable function-pointer
shapes. Remove wrappers whose only purpose is to hide missing metadata.

### Fake Elixir modules for Rust paths

Use ordinary external remote types or explicit path metadata. Do not create
empty Elixir modules merely to make generated Rust look namespaced.

### Architecture tests made from grep

Behavioral tests should compile and exercise generated output. Enforce project
architecture with Reach, Credo, ExDNA, or another architecture tool—not brittle
source-string assertions.

## Porting an existing Rustler binding

1. Keep clear domain Rust as Rust.
2. Identify duplicated boundary facts and generated glue.
3. Expose real Rust through `rust_sources` or `rust_packages`.
4. Move public entrypoints to `defnif` where RustQ can own the boundary.
5. Move reusable generated behavior to `defrust`/`defrustp`.
6. Use AST or templates for remaining generated structure.
7. Keep explicit policy in one manifest or native module.
8. Check generated files with `mix rustq.gen --check` when they are committed.
9. Run Cargo format, check, Clippy, behavioral tests, and downstream CI.

Do not migrate code merely to make a percentage larger. A clear domain parser or
renderer may remain handwritten Rust; repetitive wrappers and codecs are the
better first target.

## Verification

For non-trivial generator changes, run:

```bash
mix ci
mix rustq.gen --check
cargo fmt --check
cargo check
cargo clippy -- -D warnings
```

Also test at least one real downstream crate when shared inference, metadata,
AST, or Rustler generation changes. Clippy-clean Rust is necessary, but the
Elixir that generated it must remain readable too.
