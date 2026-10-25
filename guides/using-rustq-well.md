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
to spell an external Rust type. A function that returns a borrow from one of
several references names the lifetime: `R.ref(Record.t(), R.lifetime(:a))` is
`&'a Record`, and `R.slice(type, R.lifetime(:a))` is `&'a [T]`.

Use ordinary `@type` declarations for RustQ-owned shapes. Maps and Elixir
structs can derive Rust structs and directional codecs; atom unions can derive
unit enums; unions of structural types can derive tagged enums. Use `@typep`
for shapes that never cross the NIF boundary; see
[Model data as Elixir data](#model-data-as-elixir-data).

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
- RustQ modules named through `alias`, and `callable_modules`
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

## Share Rust through modules

`rust_sources` reads Rust a module calls but does not own. Rust a module emits
as it is, such as a runtime a library's generated code includes, is what the
module provides. Ship it in `templates/` beside the module, named as the
module's file is:

```text
lib/my_lib/runtime.ex             # defmodule MyLib.Runtime do use RustQ.Meta end
lib/my_lib/templates/runtime.rs
```

`provides: ["other.rs"]` names other files, relative to the module's file, and
`provides: []` none. Mix recompiles the module when its Rust file changes,
appears, or goes.

Its functions and methods join the module's own callables, and each Rust type
without lifetimes or type parameters becomes an Elixir type: `Record` is
`record()`. `__rustq_items__/0` and `__rustq_source__/0` emit the Rust.

Other modules use it as Elixir modules use each other, by naming it:

```elixir
alias MyLib.Runtime

@spec first(R.slice(R.u8())) :: R.nif_result(R.option(R.u32()))
defrust first(bytes) do
  record = Runtime.decode_record(bytes)
  {:ok, record.get(0)}
end
```

A RustQ module named through `alias` in a spec, a type, or a `defrust` body is
imported as `callable_modules` would import it, and `Runtime.decode_record(...)`
is the Rust call `decode_record(...)`. Neither side knows where the Rust file
is. Other aliases stay Rust paths: `SkiaSafe.Canvas.t()` is still
`skia_safe::Canvas`. `callable_modules` remains for modules a body calls
without naming them.

The Rust modules a module's `defrustmod`s map come with it, under the alias
naming it. A module maps itself with `defrustmod __MODULE__`:

```elixir
defmodule MyLib.Runtime do
  use RustQ.Meta

  defrustmod __MODULE__, as: [:my_lib_records]
  defrustmod Limits, as: [:my_lib_limits]
end
```

Then `Runtime.Record.FIRST` is `my_lib_records::Record::FIRST` and
`Runtime.Limits.MAX` is `my_lib_limits::MAX` in a module that aliases it.

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

## Model data as Elixir data

Declare the shapes a module works with as types, and build and match them the
way Elixir does. `@typep` declares a Rust-only type: the struct or enum without
the term decoder a `@type` gets, so it may hold values that have no term codec.
An `R.enum` variant is a tagged tuple, or a bare atom when it has no payload:

```elixir
@typep size :: %{required(:width) => float(), required(:height) => float()}
@typep shape :: R.enum(circle: [float()], rect: [size()], empty: [])

@spec area(R.ref(shape())) :: float()
defrust area({:circle, r}), do: 3.14159 * r * r
defrust area({:rect, size}), do: size.width * size.height
defrust area(:empty), do: 0.0
```

```rust
pub enum Shape {
    Circle(f64),
    Rect(Size),
    Empty,
}

fn area(arg1: &Shape) -> f64 {
    match arg1 {
        Shape::Circle(r) => 3.14159 * r * r,
        Shape::Rect(size) => size.width * size.height,
        Shape::Empty => 0.0,
    }
}
```

Tagged tuples construct variants too, wherever the enum is expected:
`{:circle, 1.0}` is `Shape::Circle(1.0)`. Wrap a declared type in
`R.hashable/1` to also derive `PartialEq`, `Eq`, and `Hash` so it can key a map
or set: `@typep id :: R.hashable(R.enum(source: [R.u32()], clone: [path()]))`.
Within a pattern, a constant such as `Kind.PLAIN` matches the Rust constant
reached through the module's Rust module aliases.

Update a struct with Elixir's update syntax, and let comprehensions, captures,
and `container[key]` say what they mean:

```elixir
@typep item :: %{
         required(:name) => String.t(),
         required(:shape) => shape(),
         required(:count) => integer()
       }

@spec restock(item(), integer()) :: item()
defrust restock(item, extra), do: %{item | count: item.count + extra}

@spec in_stock([item()]) :: [String.t()]
defrust in_stock(items), do: for(item <- items, item.count > 0, do: item.name)

@spec counts(R.ref(%{String.t() => integer()}), [String.t()]) :: [integer()]
defrust counts(stock, names), do: for(name <- names, do: stock[name])

@spec doubled([integer()]) :: [integer()]
defrust doubled(values), do: Enum.map(values, &(&1 * 2))
```

```rust
fn restock(item: Item, extra: i64) -> Item {
    Item {
        count: item.count + extra,
        ..item
    }
}

fn counts(stock: &HashMap<String, i64>, names: Vec<String>) -> Vec<i64> {
    names.into_iter().map(|name| stock[&name]).collect()
}

fn doubled(values: Vec<i64>) -> Vec<i64> {
    values.into_iter().map(|value| value * 2).collect::<Vec<i64>>()
}
```

A comprehension used as a value becomes an iterator pipeline collected into the
expected type, so `into:` follows the target type, as in
`for {key, value} <- pairs, into: HashMap.new(), do: {key, value}`. Run for its
effects, it becomes nested `for` loops. Generators may use patterns that can
fail to match; non-matching items are skipped, as in Elixir.

The items of a typed list keep their type inside a comprehension or an `Enum`
function's closure, so `for item <- items, do: %{item | count: 0}` updates each
`Item`. A closure runs once per item, so a struct it updates from outside the
closure is cloned rather than moved, and a later generator over a list from
outside the comprehension copies its items rather than consuming it. Indexing a
map borrows the key, and `%{key => value}` in a spec is a `HashMap`.

Elixir never changes a list, so an `Enum` function takes an owned list only at
its last use. A list the function's closure, a later expression, or a value
still in use was built from is borrowed instead: `Enum.map(records, ...)` after
`by_id = index(records)` iterates `records.iter()`. Questions such as
`Enum.any?/2` borrow regardless, items a filter keeps from a borrowed list are
cloned, and numbers and atoms are copied out. A list reached through a
reference, as a field of a borrowed struct, is always borrowed, and a
comprehension over it, or over an owned list still in use, copies its items. A
new value passed where a reference is expected, as `HashSet.new()`, is
borrowed.

Keyed collections follow the same rules. On a `HashMap` (`%{key => value}` in
a spec) or `HashSet` (`MapSet.t(item)`), `Map.get`, `fetch!`, `has_key?`,
`put`, `delete`, `merge`, `update/4`, `keys`, `values`, `to_list`, and `new`,
and `MapSet.new`, `put`, `delete`, `member?`, `union`, `difference`,
`intersection`, `subset?`, `disjoint?`, `size`, and `to_list` keep Elixir's
meaning: values read out are copies, and an update takes the collection only at
its last use, updating a copy otherwise.

`Enum` also lowers `into`, `group_by`, `with_index`, `find_index`,
`find_value`, `reduce_while`, `sort_by`, `max_by`, `min_by`, `max`, `min`,
`uniq`, `uniq_by`, `dedup`, `split_with`, `at`, `slice`, `take_while`,
`drop_while`, `zip_with`, `chunk_every`, `join`, and `map_join`. A few follow
Rust where Elixir cannot be kept exactly:

- `with_index` indexes in `usize`, and a generator over it enumerates in place:
  `for {child, index} <- Enum.with_index(children)` is
  `for (index, child) in children.iter().enumerate()`.
- `find_value` takes a function returning `some(value)` or `nil`.
- `reduce_while` reads `{:cont, acc}` and `{:halt, acc}` as `try_fold` does.
- `max_by`, `min_by`, `max`, and `min` need an empty fallback, `fn -> nil end`
  for an `Option`, since Elixir raises on an empty list.
- Sort and extremum keys are values, as in Elixir: a key read out of an item is
  cloned, not borrowed.
- `at`, `slice`, and `chunk_every` take non-negative indexes and counts.

A generator over one value matches it beside the item, so
`for record <- records, {:some, id} <- [record_id(record)], do: {id, record}`
skips records without an id, the way `filter_map` does, without making a list
for each.

Types another module declares or provides are available once the module is
named through `alias` or listed in `callable_modules`. Write them remotely, as `Shapes.shape()`, since Elixir checks local types; they keep
their single Rust declaration in the module that declares them.

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

## Conditional Rust helpers

Use `@cfg` before `defrust` or `defrustp` to emit a Cargo compile-time
condition. RustQ does not evaluate the predicate during Elixir compilation.

```elixir
@spec normalize(integer()) :: integer()

@cfg feature: "extended"
defrust normalize(0), do: 0
defrust normalize(value), do: value + 1

@cfg not: [feature: "extended"]
defrust normalize(value), do: value
```

A condition belongs to the following implementation group. Consecutive clauses
of the same function inherit it; another `@cfg` begins a separate implementation.
A different function ends that inheritance. Keep the function's shared `@spec`
outside the groups. Do not mix unconditional and conditional implementations.

Compose predicates with keyword lists, preserving repeated keys:

```elixir
@cfg all: [feature: "native-test", not: [target_os: "windows"]]
@cfg any: [target_os: "linux", target_os: "macos"]
```

These are alternative examples, not two attributes to stack on one declaration.
Only one pending `@cfg` is allowed. `not` requires exactly one predicate.
Identical conditions are rejected, but RustQ does not prove arbitrary predicates
mutually exclusive or exhaustive; compile every supported Cargo configuration.
implementations of the same signature must use the same NIF scheduling policy.
`@cfg` also supports `defnif`: Rust entrypoints, result codecs, and internal
implementation helpers carry their conditions, while Elixir exposes one stub.
Compile every supported configuration to ensure exactly one implementation is
selected. Conditional payload types themselves are not inferred or generated
from feature conditions.

Conditional methods are supported inside `defrustimpl`. A receiver named other
than `self` is bound locally to the Rust receiver, preserving ordinary lexical
shadowing. `RustQ.Meta.AST.functions/1` returns every conditional function
implementation with its attributes intact. `function!/2` rejects ambiguous
names instead of selecting an arbitrary implementation. Callable signatures
remain shared and are not filtered according to the local machine's features.

The AST builder accepts the same recursive structure:
`A.attr(:cfg, not: [feature: "native-test"])`.

## Native closures

Use ordinary Elixir function syntax for callback bodies. `move(fn ... end)`
explicitly transfers captures into the Rust closure; clone shared values before
capture when required. Moving captures does not by itself imply `FnOnce`.

```elixir
@spec callback(String.t()) ::
        R.impl((-> R.usize()), traits: [Send.t()], lifetime: R.lifetime(:static))
defrust callback(label) do
  move(fn -> label.len() end)
end
```

This returns `impl Fn() -> usize + Send + 'static`. `R.impl` also accepts
`kind: :fn_mut` and `kind: :fn_once`; the default is `:fn`. A `'static` bound
forbids retaining shorter-lived borrows, not normal destruction of owned values.
These are native callable types, not BEAM callback codecs.

Tuple patterns and wildcards work in closure parameters. AST generators can
use `{pattern, type}` arguments with `A.closure(args, body, move: true)` when an
explicit Rust parameter annotation is necessary. Known callback parameter types
participate in borrowing inference, but generic trait solving is not complete.

Source-backed receiver inference supports a limited set of root type aliases
and qualified standard-library pointer types. Unsupported lifetime aliases and
requested nested or ambiguous aliases fail explicitly; this is not a complete
Rust module or reexport resolver.

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
