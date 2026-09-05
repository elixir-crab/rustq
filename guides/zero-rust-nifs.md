# Zero-handwritten-Rust NIFs

`RustQ.Native` generates, builds, and loads a Rustler crate from typed
Rusty-Elixir. It is the default starting point when RustQ should own an ordinary
NIF boundary.

```elixir
defmodule MyApp.Native do
  use RustQ.Native, crates: [crc32fast: "1"]

  alias RustQ.Type, as: R

  @spec checksum(String.t()) :: R.u32()
  defnif checksum(value), do: Crc32fast.hash(value.as_bytes())
end
```

The module above needs no checked-in `.rs` file, `Cargo.toml`, NIF registry,
Elixir stub module, or loader. RustQ generates those pieces under the Mix build
directory and keeps the generated crate available for inspection.

For authoring conventions and inference, read
[Using RustQ Well](using-rustq-well.md). This guide focuses on crate ownership
and the NIF boundary.

## Public entrypoints and helpers

Use each function form for one responsibility:

- `defnif` — public BEAM↔Rust entrypoint
- `defrust` — generated public Rust helper
- `defrustp` — generated private Rust helper

All three use real `@spec`s. Ordinary Elixir macros are the preferred way to
reuse Rusty-Elixir source.

```elixir
@spec add(integer(), integer()) :: integer()
defnif add(left, right), do: add_impl(left, right)

@spec add_impl(integer(), integer()) :: integer()
defrustp add_impl(left, right), do: left + right
```

## What RustQ owns

For a normal `RustQ.Native` module, RustQ owns:

- the generated Cargo package and source
- declared Cargo dependencies
- Rustler attributes and initialization
- Elixir exports and native loading
- directional argument and return codecs
- generated atoms, structural types, and resources
- native compilation and installation into the application

Use `crates:` when generated code calls an external crate:

```elixir
use RustQ.Native,
  crates: [
    crc32fast: "1",
    serde_json: [version: "1", features: ["preserve_order"]]
  ]
```

RustQ derives Rust module aliases from crate names. Cargo versions and features
remain explicit because they are release policy, not inference.

## Boundary types

RustQ derives directional codecs from `@spec` and `@type`. Supported boundary
families include:

- integers, floats, booleans, atoms, strings, and binaries
- tuples and homogeneous lists
- options and tagged results
- typed maps and Elixir structs
- unit enums and structural unions
- Elixir exceptions
- explicitly declared resources

Elixir-facing, Rust-internal, NIF-input, and NIF-output representations are
related but not assumed identical. For example, an Elixir binary can decode as a
borrowed Rustler binary, be used internally as bytes, and encode from owned
bytes.

A structural map type can own the codec for a NIF value:

```elixir
@type point :: %{required(:x) => float(), required(:y) => float()}

@spec scale(point(), float()) :: point()
defnif scale(point, factor) do
  %{x: point.x * factor, y: point.y * factor}
end
```

## Numeric boundaries and arithmetic

Rusty-Elixir uses native numeric representations, not BEAM arbitrary-precision
arithmetic. `integer()` maps to Rust `i64`, and `float()` maps to `f64`.
Use `R.i8()` through `R.i64()`, unsigned types, or `R.f32()` when the native
width is part of the contract. Integer inputs outside the declared type's range
are rejected at the NIF boundary.

Keep arithmetic policy explicit:

- `div/2` and `rem/2` on valid signed integer operands truncate toward zero,
  matching Elixir. A zero divisor and signed minimum divided by `-1` are not
  valid ordinary Rust integer division operations.
- Use native `checked_add`, `checked_sub`, `checked_mul`, `checked_div`, and
  `checked_rem` methods when overflow or invalid division must be represented
  as a value. With an `R.option(...)` return type, `None` is encoded as `nil`.
- `/` with statically known integer operands is rejected. Convert explicitly
  with `cast(value, R.f64())` when floating-point division is intended. This
  conversion can lose precision for large integers.
- Ordinary integer `+`, `-`, and `*` retain the owning Rust crate's overflow
  behavior. Do not rely on debug/release overflow behavior being identical;
  use checked operations when failure is part of the API.
- Floating-point arithmetic follows Rust/IEEE-754 behavior, not Elixir's
  arithmetic exception rules. In particular, reject zero divisors explicitly
  if the API must not produce non-finite values. Do not assume such values are
  portable through every BEAM codec.

```elixir
@spec checked_total(R.i64(), R.i64()) :: R.option(R.i64())
defnif checked_total(left, right), do: left.checked_add(right)
```

RustQ does not add big-integer emulation or silently choose an overflow policy
for an externally owned crate.

## Resources

Wrap a structural state type with `R.resource/1` to derive registration and the
`ResourceArc` boundary:

```elixir
@type counter_state :: %{required(:value) => integer()}
@type counter :: R.resource(counter_state())

@spec new_counter(integer()) :: counter()
defnif new_counter(value), do: %{value: value}

@spec counter_value(counter()) :: integer()
defnif counter_value(counter), do: counter.value
```

`R.resource/1` does not choose mutation, synchronization, ownership, or thread
safety. Those decisions remain explicit and may require a deliberately designed
state type or nearby handwritten Rust.

## Scheduling

A `defnif` uses the normal BEAM scheduler by default. Mark only entrypoints that
need dirty scheduling:

```elixir
@nif schedule: :dirty_cpu
@spec resize_image(binary()) :: binary()
defnif resize_image(image), do: resize_impl(image)

@nif schedule: :dirty_io
@spec read_device(String.t()) :: binary()
defnif read_device(path), do: read_device_impl(path)
```

Use `:dirty_cpu` for long-running CPU-bound work and `:dirty_io` for native work
that may block on IO. The attribute applies only to the declaration immediately
following it. RustQ renders the Rustler `"DirtyCpu"` and `"DirtyIo"` options;
those strings are accepted directly, but atoms are the preferred spelling.

RustQ does not infer scheduling from a function body. Short NIFs should normally
stay on the normal scheduler.

## Existing and precompiled crates

An existing crate can keep Cargo, initialization, loading, and release ownership
while RustQ prepares ABI items:

```elixir
defmodule MyApp.NativeItems do
  use RustQ.Native,
    build: false,
    load: false,
    rust_sources: ["native/my_app/src/lib.rs"]

  alias RustQ.Type, as: R

  @spec decode(term()) :: R.nif_result(term())
  defnif decode(value), do: decode_impl(nif_env(), value)
end
```

`RustQ.Native.items/1` returns the prepared functions, codecs, and resource
items for the owning crate to splice. `RustQ.Native.source/1` returns the same
prepared source when an external system needs text.

`nif_env/0` injects `Env<'a>` into generated Rust without adding an argument to
the public BEAM function. Use this mode for source-built or precompiled domain
crates that should not depend on RustQ in production.

## Supported Rusty-Elixir

`defnif` and `defrust` share the same lowering surface. It includes multiple
clauses, patterns, guards, recursion, `case`, conditionals, `with`,
comprehensions, closures, pipelines, ordinary macro expansion, and a
semantics-preserving subset of Kernel, Enum, List, typed Map, String, Tuple, and
Range operations.

The subset is intentionally semantic, not name-based. RustQ rejects operations
that cannot preserve Elixir behavior instead of silently choosing a similar
Rust method. Dynamic or descending ranges, unrestricted dynamic maps,
grapheme-counting `String.length/1`, process semantics, full protocols, async
Rust, IO/network/process APIs, and the complete bitstring grammar remain
explicit adapters or Rust boundaries.

See [Using RustQ Well](using-rustq-well.md) for the authoring ladder and
inference rules. The API reference for `RustQ.Meta` documents individual forms.

## Testing

Use the packaged assertions instead of searching build directories:

```elixir
use RustQ.Test, async: true

assert rust_source!(MyApp.Native, :add_impl) =~ "fn add_impl"
assert rust_source!(MyApp.Native, :add) =~ ~r/fn add/
assert nif_exported?(MyApp.Native, :add, 2)
assert RustQ.valid?(rust_source!(MyApp.Native), "my_app_native.rs")
```

`rust_source!/2` returns one focused function for ordinary ExUnit assertions,
while `rust_source!/1` returns the complete generated module.
`nif_exported?/3` checks both the Elixir export and generated Rustler attribute.
Use `RustQ.valid?/2` when the test specifically needs Rust syntax validation.

## Explicit policy checklist

Before shipping a native module, review:

- dependency versions and Cargo features
- scheduler choice and blocking behavior
- resource ownership and thread safety
- unsafe operations
- lossy conversions and custom adapters
- platform linking
- precompiled targets and artifact hosting

Zero handwritten bridge Rust means RustQ derives repetitive structure. It does
not mean RustQ guesses safety or deployment decisions.
