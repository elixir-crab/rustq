---
name: rustq
summary: Build readable Elixir↔Rust bridges with RustQ in new NIF projects, ports of existing bindings, and code generators. Use Rusty-Elixir/defrust, inference, Rust source metadata, Elixir macros, and RustQ AST before raw Rust strings.
---

# RustQ Skill

Use this skill when starting a RustQ-powered NIF/bridge, porting existing Rustler bindings, adding generated Rust to an Elixir project, or working on RustQ itself.

RustQ's goal is a readable and maintainable Elixir↔Rust bridge. Generated Rust should be understandable through the Elixir that produced it. Do not turn RustQ projects into cryptic string emitters.

Full guide: https://rustq.hexdocs.pm/using-rustq-well.md

## First principles

1. **Write bridge behavior as Rusty-Elixir.** Prefer `defnif` for public NIF entrypoints and `defrust`/`defrustp` helpers with real `@spec`s.
2. **Let RustQ infer.** Do not sprinkle `unwrap!` everywhere. RustQ can infer many `?` propagations from return types, argument types, receiver types, and Rust source callable metadata.
3. **Use Elixir metaprogramming.** Use ordinary `defmacro`, `quote`, `unquote`, pattern matching, recursion, and schema transforms.
4. **Infer from Rust/source schemas.** Use `RustQ.Syn`, `rust_sources`, `rust_packages`, and `callable_modules` instead of hand-copying Rust APIs.
5. **Use RustQ AST/builders for generated structure.** If a construct is missing, prefer adding RustQ support over writing a large string template.
6. **Keep raw Rust strings tiny and local.** Macro invocations and unavoidable syntax escapes are fine; large generated functions as strings are not.
7. **Respect the public compatibility boundary.** Use documented modules and generated accessors; do not import hidden renderer, native NIF, lowering, inference, cache, or schema-introspection modules.

## Zero-handwritten-Rust target

RustQ 1.0 targets `use RustQ.Native` plus `defnif` as the default starting point for ordinary bridges. RustQ should generate the crate, Rustler initialization, loader, codecs, atoms, and stubs; a simple consumer should not need a checked-in `.rs` file, `Cargo.toml`, or `rustq.exs`.

Keep real policy explicit: Cargo dependencies/features, scheduler choice, resources and thread-safety, blocking or unsafe operations, lossy conversions, external adapters, and precompiled-release targets. Zero handwritten bridge Rust does not mean silently guessing those decisions.

A `defnif` uses the normal BEAM scheduler unless explicitly annotated. Put the
policy immediately before the affected entrypoint:

```elixir
@nif schedule: :dirty_cpu
@spec render_scene(Scene.t()) :: binary()
defnif render_scene(scene), do: render_scene_impl(scene)

@nif schedule: :dirty_io
@spec read_device(String.t()) :: binary()
defnif read_device(path), do: read_device_impl(path)
```

Use `:dirty_cpu` for long CPU-bound native work and `:dirty_io` for native work
that may block on IO. The attribute applies only to the next declaration; do not
mark short NIFs dirty by default or expect RustQ to infer scheduling policy.

See [`guides/zero-rust-nifs.md`](guides/zero-rust-nifs.md) for the 1.0 target and supported-subset boundary.

For an existing source-built or precompiled crate, use
`RustQ.Native, build: false, load: false` and splice
`RustQ.Native.items/1`. This keeps Cargo, loading, initialization, and release
policy with the existing crate while still deriving native boundary items. Use
`nif_env/0` when a dynamic `Term` adapter needs Rustler's `Env`; RustQ injects
the Rust argument without adding a public BEAM argument.

## 1.x compatibility discipline

RustQ's compatibility contract is documented in [`guides/compatibility.md`](guides/compatibility.md) and published in HexDocs. When changing RustQ or a consumer:

- treat documented Rusty-Elixir forms, public AST schemas/builders, Rustler helpers, diagnostics, and Reach finding kinds as the stable surface
- treat `RustQ.Meta.AST` as the public structural accessor for compiled `defrust` metadata; use `RustQ.Meta.AST.functions/1` or `function!/2` instead of calling the hidden `__rustq_asts__/0` accessor directly, while `@moduledoc false`, `@doc false`, the hidden AST renderer, native NIF implementation, lowerer, inference engine, caches, and other implementation modules remain unstable
- expect generated Rust to be deterministic for one RustQ and formatter version, but not byte-identical across upgrades; regenerate checked-in output after dependency updates
- classify new lowering forms and Reach checks as additive minor changes; reserve semantic changes to documented valid forms for a major release unless correcting invalid, unsafe, or contradicted behavior
- validate package contents and documented APIs through the external public-consumer fixture before release

## Starting point for a new bridge

```elixir
defmodule MyApp.Native.Generated do
  use RustQ.Meta,
    rust_sources: ["native/my_app_nif/src/helpers.rs"]

  alias RustQ.Type, as: R

  @spec decode_color(R.term()) :: R.nif_result(R.raw(:Color))
  defrust decode_color(term) do
    value = decode_as!(term, R.u32())
    {:ok, Color.from_argb(255, 0, 0, value)}
  end

  @spec draw(R.mut_ref(Canvas.t()), R.term()) :: R.nif_result(R.unit())
  defrust draw(canvas, term) do
    color = decode_color(term)
    canvas.draw_color(color)
    :ok
  end
end
```

If RustQ knows `decode_color/1` returns `NifResult<Color>` and `draw_color/1` expects `Color`, it can lower the call as `decode_color(term)?` in the argument position. You do not need to write `unwrap!` just to force `?`.

## Prefer inference over `unwrap!`

`unwrap!` still exists as an explicit `?` escape hatch, but it should not be the default style for every fallible call. Before using it, first make sure RustQ can see the callable metadata that would let it infer propagation.

Prefer this when callable metadata is available:

```elixir
@spec draw(R.term(), R.slice({R.atom(), R.term()})) :: R.nif_result(R.unit())
defrust draw(term, opts) do
  stroke_paint(decode_color(term), 1.0, opts)
  :ok
end
```

RustQ can infer propagation from:

- return-position expected wrappers (`NifResult<T>`, `Result<T, E>`, `Option<T>`)
- argument types from local `@spec`s
- argument types from `callable_modules`
- Rust free functions and impl methods parsed from `rust_sources` / `rust_packages`
- receiver method calls when the receiver type is known
- downstream uses of previously-bound locals
- case scrutinees, `some(...)`, `decode_as!`, `map_get`, and fallible ref access
- vector/slice borrows, list literals, vector pushes, and iterator-like argument expectations
- common adapters such as `impl AsRef<T>` and `impl Into<Option<T>>`

Before reaching for `unwrap!`, check:

- Is the callable defined by a local `@spec`?
- Is it exposed through a `callable_modules` module?
- Is it parseable from configured `rust_sources`?
- Is it available from configured `rust_packages`?
- Is the receiver type known well enough for method lookup?
- Is the expected return or argument type known?

If a fallible call is a method on a Rust type, read the Rust source that defines it and configure metadata before assuming RustQ cannot infer it. Do not use `unwrap!`, verbose `case`, or raw Rust wrappers to paper over missing metadata.

Use `unwrap!` only when you genuinely need to force propagation and metadata/inference cannot express the shape yet:

```elixir
@spec decode_alpha(R.term()) :: R.nif_result(R.u8())
defrust decode_alpha(term) do
  value = decode_as!(term, R.u32())
  {:ok, cast(value, R.u8())}
end
```

Use `ok_or!` for explicit `Option<T>` to `Result`/`NifResult` boundaries:

```elixir
@spec shader(R.ref(Paint.t())) :: R.nif_result(Shader.t())
defrust shader(paint) do
  ok_or!(paint.shader(), badarg())
end
```

## Use Rust source metadata

Do not retype Rust APIs into Elixir registries when RustQ can read them.

```elixir
defmodule MyApp.Native.Generated do
  use RustQ.Meta,
    rust_sources: [
      "native/my_app_nif/src/paint.rs",
      "native/my_app_nif/src/generated.rs"
    ],
    rust_packages: [{"skia-safe", manifest_path: "native/my_app_nif/Cargo.toml"}],
    callable_modules: [MyApp.Native.GeneratedEnums]

  alias RustQ.Type, as: R

  @spec run(R.mut_ref(Paint.t()), R.atom()) :: R.nif_result(R.unit())
  defrust run(paint, atom) do
    paint.set_stroke_cap(decode_cap(atom))
    :ok
  end
end
```

RustQ parses callable signatures and uses them for propagation/argument inference.
This is the preferred way to bridge existing Rust libraries.

When a `defrust` function calls a Rust method such as `decoder.read_var_int64()`, the correct first move is to expose the `Decoder` implementation through `rust_sources` or equivalent callable metadata. Do not duplicate the method signature in an ad hoc Elixir registry or hide missing metadata behind wrappers.

## Do not create trivial wrappers for missing metadata

Do not create a new Rust or `defrust` helper merely to call one Rust method and return `Ok(())`:

```elixir
# Bad if the only reason is that RustQ cannot see `Decoder.read_var_int64/0` yet.
@spec kiwi_skip_int64_value(R.mut_ref(R.path(:Decoder, R.lifetime(:_)))) :: R.nif_result(R.unit())
defrust kiwi_skip_int64_value(decoder) do
  unwrap!(decoder.read_var_int64())
  :ok
end
```

First make RustQ understand the underlying Rust method via `rust_sources`, `rust_packages`, or `callable_modules`, or improve RustQ inference if the metadata is present but unused. Wrappers are fine when they encode real bridge semantics or are required as stable function-pointer targets, but they should not be a workaround for skipped metadata.

## Use recursion and reducers instead of return/break-driven product code

RustQ has internal AST nodes for Rust `return`, `loop`, `break`, and `continue`, but bridge/generator code should usually be written as Elixir-shaped control flow.

Prefer recursion for small state machines:

```elixir
@spec skip_remaining(R.mut_ref(Decoder.t()), R.u32()) :: R.nif_result(R.unit())
defrust skip_remaining(decoder, remaining) do
  if remaining == 0 do
    :ok
  else
    skip_one(decoder)
    skip_remaining(decoder, remaining - 1)
  end
end
```

Prefer `for ..., reduce:` for accumulator loops:

```elixir
@spec validate_all(R.vec(Item.t())) :: R.nif_result(R.unit())
defrust validate_all(items) do
  for item <- items, reduce: :ok do
    :ok -> validate_item(item)
  end
end
```

Use `return!`, `break`, and `continue` only when modelling an inherently Rusty low-level primitive or RustQ internals. They should be unusual in downstream product generators.

## Use `defrustimpl` for Rust methods

Use `defrustimpl` when Rusty-Elixir functions belong to an inherent or trait
implementation. Keep the receiver as the first valid-Elixir argument and type it
with `R.ref/1` or `R.mut_ref/1`; RustQ renders those as `&self` and `&mut self`.

```elixir
defrustimpl ComponentRegistry, vis: :crate do
  @spec input_mut(R.mut_ref(R.path(:ComponentRegistry)), R.str()) ::
          R.option(R.mut_ref(R.path(:ComponentInput)))
  defrust input_mut(self, id) do
    self.entries.get_mut(ref(id))
  end
end
```

For trait implementations, use `:for`:

```elixir
defrustimpl Display, for: Widget do
  @spec display(R.ref(R.path(:Widget))) :: R.str()
  defrust display(self), do: self.label.as_str()
end
```

Use `:vis`, `:attrs`, and `:lifetimes` for implementation metadata. Prefer this
API over compiling free `defrust` functions and manually rewriting their AST
arguments into receivers.

## Use ordinary Elixir macros for reusable Rusty-Elixir

```elixir
defmacro with_saved_canvas(do: body) do
  quote do
    var!(canvas).save()
    unquote(body)
    var!(canvas).restore()
  end
end

@spec draw(R.ref(Canvas.t())) :: R.nif_result(R.unit())
defrust draw(canvas) do
  with_saved_canvas do
    canvas.translate({1.0, 2.0})
  end

  :ok
end
```

RustQ expands normal Elixir macros before lowering. Use that power instead of generating Rust strings.

Use ordinary Elixir macros when you want reusable Rusty-Elixir source. They run
while compiling the Elixir generator and do not intentionally leave a Rust macro
in the output.

For repeated generated bridge code, first use normal Elixir metaprogramming:
helper functions that return quoted Rusty-Elixir, `defmacro`, `quote`, `unquote`,
`unquote_splicing`, schema transforms, `Enum.map`, recursion, and pattern
matching. RustQ is designed to lower valid Elixir-shaped Rusty-Elixir; do not
invent a separate mini-language or string template when ordinary Elixir can
produce the Rusty-Elixir you need.

Use `defrustmacro` for the different case where repeated generated Rust should
call one compact `macro_rules!` helper while the helper body remains
Rusty-Elixir:

```elixir
defrustmacro field(term, name, type: :ty) do
  decode_as!(required_field(term, name), type)
end
```

Plain arguments are `:expr` fragments; annotate type arguments with `:ty`. Use
`:ident` and `:literal` when a macro captures Rust identifiers or literal tokens.
Do not write Rust syntax in the body. In short: `defmacro` improves the authoring
layer; `defrustmacro` intentionally changes the generated Rust shape.

`defrustmacro` can also emit Rust items when the body contains normal Rusty-Elixir
`defrust`. Keep the signature declarative and put the implementation in the inner
`defrust` body:

```elixir
defrustmacro sparse_message(
  fn: name(:ident),
  env: env(:ident),
  decoder: decoder(:ident),
  module: module_name(:literal),
  capacity: capacity(:literal),
  fields:
    repeat do
      field_id(:literal)
      field_name(:literal)
      field_mode(:ident)
      field_decode(:ident)
    end
) do
  @spec name(R.path(:Env, R.lifetime(:a)), R.mut_ref(R.path(:Decoder))) ::
          R.nif_result(term())
  defrust name(env, decoder) do
    decode_sparse_fields(
      env,
      decoder,
      module_name,
      capacity,
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
```

Inside `defrustmacro`, declared captures such as `env`, `module_name`, and
`field_id` lower to Rust macro variables (`$env`, `$module_name`, `$field_id`).
`repeat fields do ... end` is a macro-template repetition, not a runtime loop.
Use it only in the documented `defrustmacro` capture/template positions. If you
need to assemble repeated Rusty-Elixir statements or helper bodies, prefer
ordinary Elixir `quote`/`unquote_splicing` or helper macros at the authoring
layer instead of adding new RustQ-specific syntax.

## Use the supported Rusty-Elixir surface

Common supported forms include:

- `@spec` / `@type` driven function signatures
- ordinary assignments (`let`) and inferred mutability when later assigned
- multiple clauses, recursion, `case`, `if`, `unless`, `cond`, `with`, and guards
- tuple, list head/tail, map, struct, option/result, atom, and literal patterns
- comprehensions and the documented Kernel, Enum, List, typed Map, String
  predicate, Tuple, and ascending Range subset
- method calls, remote calls, local calls, aliases, pipelines
- `decode_as/2` and `decode_as!/2` for Rustler term decoding
- `ref/1`, `mut_ref/1`, `deref/1`, `cast/2`, `array/1`, `index/2`, `struct_literal/2`
- `expr!`, `pat!`, `stmt!`, and `arm!` for semantic Rust-shaped AST values authored as valid Elixir
- `raw_expr!`, `raw_pat!`, `raw_stmt!`, and `raw_arm!` only as explicit token escapes

## Types: prefer clear specs

Use ordinary Elixir and remote types first:

```elixir
@spec draw(R.ref(SkiaSafe.Canvas.t()), GeneratedOpts.CircleOpts.t(R.lifetime(:a))) ::
        R.nif_result(R.unit())
```

Use `RustQ.Type` (`alias RustQ.Type, as: R`) for Rust-specific precision:

- `R.ref/1`, `R.mut_ref/1`, `R.slice/1`
- fixed-width numbers: `R.u32()`, `R.i64()`, `R.f32()`
- `R.nif_result/1`, `R.result/2`, `R.option/1`, `R.vec/1`, `R.resource/1`
- `R.lifetime/1`
- `R.raw/1` and `R.path/1,2` as low-level escapes

Do not invent fake Elixir modules solely to spell Rust paths. Do not assume a
similarly named Rust method preserves Elixir semantics: for example,
`String.length/1` counts graphemes and must not become `.chars().count()`.
Unsupported stdlib behavior belongs behind an explicit adapter.

## Generate Rust type items from `@type`

RustQ can emit Rust type declarations from ordinary Elixir `@type` aliases.
Use this before hand-building Rust struct/enum/type-alias strings.

Map types become Rust structs:

```elixir
@type point :: %{
  required(:x) => R.f32(),
  required(:y) => R.f32()
}
```

Struct types become Rust structs too:

```elixir
defmodule Click do
  defstruct [:name]
end

@type click :: %Click{name: String.t()}
```

Atom unions become Rust enums, and struct unions become tuple enums:

```elixir
@type mode :: :src_over | :multiply
@type event :: click() | resize() | scroll()
```

Use `R.enum(...)` when you need an explicit Rust enum with tuple payloads but do
not want to overload ordinary Elixir tuple unions:

```elixir
@type skip_kind :: R.enum(one: [skip_fn()], repeated: [skip_fn()], bytes: [])
```

Construct those variants from `defrust` with `enum_variant/2+`, not token macros:

```elixir
defrust kind(repeated, skip) do
  if repeated do
    enum_variant(SkipKind, :repeated, skip)
  else
    enum_variant(SkipKind, :one, skip)
  end
end
```

Type items are available through `__rustq_type_items__/0`; use them in
generators just like generated `defrust` items from `__rustq_items__/0`. This is
the preferred path for support structs such as small descriptor records used by
generated `defrust` helpers.

## AST/builders for generated structure

When generating Rust declarations, prefer RustQ AST/builders:

```elixir
alias RustQ.Rust.AST.Builder, as: A

A.const(:MAX_FIELDS, :usize, A.lit(128), vis: :pub)
```

If AST/native rendering rejects a shape you need, that is usually a RustQ capability gap. Add the missing node/decoder/rendering support rather than falling back to a giant template.

## Raw Rust strings: last resort

RustQ itself still has a few explicit low-level escape boundaries. Treat these as
owned exceptions, not examples to copy:

- core renderers/validators that must accept Rust text (`RustQ.render/3`, splice validation)
- `RustQ.Rust.AST.MacroItem`, `EscapeExpr`, and `TypeRaw` nodes, which are explicit escape nodes
- Rustler helper APIs that accept caller-provided Rust expressions for advanced dispatch/defaults
- unsafe raw `NIF_TERM` primitives where Rustler exposes only low-level operations; compose surrounding generated structure with `RustQ.Rust.AST.UnsafeBlock`

Anything outside those boundaries should use `defrust`, RustQ AST, or inferred metadata first.

Acceptable:

```elixir
A.macro_item("rustler::atoms! { ok, error }")
```

Not acceptable as normal style:

```elixir
RustQ.Rust.fragment(:item, [
  "fn decode_", name, "(decoder: &mut Decoder<'_>) -> NifResult<()> {\n",
  "    loop { ... }\n",
  "}\n"
])
```

If a raw escape grows beyond a small syntax boundary, stop and add a semantic RustQ capability.

## Test generated APIs idiomatically

Consumer tests should use `RustQ.Test` instead of reaching into build
directories or repeating source-search helpers:

```elixir
use RustQ.Test, async: true

assert rust_source!(MyApp.Native, :decode_impl) =~ "fn decode_impl"
assert rust_source!(MyApp.Native, :decode) =~ ~r/fn decode/
assert nif_exported?(MyApp.Native, :decode, 1)
assert RustQ.valid?(rust_source!(MyApp.Native), "my_app_native.rs")
```

`rust_source!/2` returns one focused function for ordinary ExUnit assertions;
`nif_exported?/3` verifies both the Elixir export and generated Rustler NIF
attribute. Keep package/build orchestration in a project test case or fixture
driver rather than embedding shell runners and temporary-workspace management
inside behavior tests.

## Porting checklist

When porting existing bindings:

1. Keep clear handwritten Rust as Rust.
2. Move repetitive bridge glue to `defrust` or AST-backed generation.
3. Configure `rust_sources` / `rust_packages` before duplicating Rust signatures.
4. Replace metadata registries with inference from Rust/schema/typespecs.
5. Add `rustq.exs`, generate checked-in Rust if needed, and enforce `mix rustq.gen --check`.
6. Run generated Rust through `cargo fmt`, `cargo check`, and `cargo clippy -- -D warnings`. For generator changes that call downstream Rust methods, run the downstream native crate too; Elixir tests alone can miss missing callable metadata or receiver-type drift.

## References

Read these in HexDocs/source when working with RustQ:

- `RustQ.Meta` — `defrust`, module options, Rusty-Elixir lowering entry point
- `RustQ.Type` — typespec vocabulary
- `RustQ.Rust.AST.Builder` — AST constructors
- `RustQ.Rust.AST.PatternBuilder` and `RustQ.Rust.AST.TypeBuilder`
- `RustQ.Syn` and `RustQ.Syn.Index` — Rust source introspection
- `RustQ.Binding.Callable`, `RustQ.Binding.Source`, `RustQ.Binding.Index` — callable metadata/inference inputs
- `RustQ.Rustler` and `RustQ.Rustler.Schema` — Rustler helper generation
- `lib/rustq/meta/` — internal lowering and inference implementation
- `guides/using-rustq-well.md` — canonical authoring and inference practices
- `guides/zero-rust-nifs.md` — `RustQ.Native`, boundaries, resources, and scheduling
- `guides/generating-rust.md` — checked files, templates, AST, splices, and validation

## Verification

For non-trivial changes:

- `mix ci`
- `mix rustq.gen --check` where applicable
- downstream dogfood CI when changing shared generators
- generated Rust: `cargo fmt --check`, `cargo check`, `cargo clippy -- -D warnings`
- compare generated size after the generator remains readable

Clippy-clean Rust is necessary, not sufficient. RustQ code should also be beautiful at the generator layer.
