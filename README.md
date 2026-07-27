# RustQ

[![Hex.pm](https://img.shields.io/badge/dynamic/json.svg?url=https%3A%2F%2Fhex.pm%2Fapi%2Fpackages%2Frustq&query=%24.latest_version&prefix=v&label=hex.pm)](https://hex.pm/packages/rustq) [![Documentation](https://img.shields.io/badge/documentation-gray.svg)](https://rustq.hexdocs.pm/)

Write native Elixir in Elixir. RustQ turns typed, Elixir-shaped code into readable
Rust and can generate, compile, and load a complete Rustler NIF without checked-in
bridge Rust.

```elixir
defmodule MyApp.Native do
  use RustQ.Native, crates: [crc32fast: "1"]

  alias RustQ.Type, as: R

  @type point :: %{required(:x) => float(), required(:y) => float()}

  @spec checksum(String.t()) :: R.u32()
  defnif checksum(value), do: Crc32fast.hash(value.as_bytes())

  @spec scale(point(), float()) :: point()
  defnif scale(point, factor) do
    %{x: point.x * factor, y: point.y * factor}
  end
end
```

That module is the bridge. RustQ derives the Cargo crate, Rustler entrypoints,
Elixir stubs, boundary codecs, initialization, build, and native loading. There
is no `.rs` file, `Cargo.toml`, atom registry, or duplicated signature list to
maintain.

## Typed Elixir in, Rust out

`defrust` uses the Elixir typespec as the Rust signature source of truth, then
lowers Elixir semantics rather than substituting text:

```elixir
defmodule MyApp.Generated do
  use RustQ.Meta

  @spec sum_squares([integer()]) :: integer()
  defrust sum_squares([]), do: 0
  defrust sum_squares([head | tail]), do: head * head + sum_squares(tail)
end
```

The list and integer types become `Vec<i64>` and `i64`; clauses and list patterns
become a Rust match:

```rust
fn sum_squares(arg1: Vec<i64>) -> i64 {
    match arg1.as_slice() {
        [] => 0,
        [head, tail @ ..] => head * head + sum_squares(tail.to_vec()),
    }
}
```

`RustQ.Type` extends normal typespecs with Rust-specific precision such as
references, fixed-width numbers, lifetimes, slices, options, results, and
`NifResult`. The same lowerer powers `defnif`, which additionally derives the
BEAM boundary and Rustler attribute. It understands guards, structs, typed maps,
comprehensions, closures, and a semantics-preserving subset of Kernel, Enum,
List, Map, String, Tuple, and Range.

## Why RustQ

Native Elixir libraries usually repeat the same facts across Elixir stubs, Rust
functions, Rustler codecs, Cargo configuration, and code generators. RustQ keeps
those facts structural and close to their source:

- `@spec` and `@type` drive Rust signatures and ABI codecs.
- `defnif`, `defrust`, and `defrustp` use ordinary Elixir syntax, pattern
  matching, guards, recursion, comprehensions, and selected standard-library
  calls.
- Real Rust source and Cargo packages provide callable and type metadata, so
  RustQ can infer borrows and fallible `?` propagation instead of requiring
  wrapper functions.
- RustQ AST, real Rust templates, and checked generation scale from one NIF to
  large schema-driven native libraries without assembling Rust strings.
- Scheduling, unsafe operations, resources, lossy conversion, dependencies,
  linking, and release targets remain explicit policy.

RustQ is for bridge and generator code. Domain-heavy parsers, renderers, and
algorithms can stay in Rust while RustQ removes the repetitive boundary glue.

## Installation

```elixir
def deps do
  [
    {:rustq, "~> 1.0.0-rc.6", runtime: false}
  ]
end
```

Projects that only run checked-in generators during development may use
`only: [:dev, :test]`. Rust and Cargo must be available wherever native modules
or generators compile.

## Choose the right workflow

| You want to… | Start with |
| --- | --- |
| Build and load a NIF without handwritten bridge Rust | `use RustQ.Native` and `defnif` |
| Generate Rust helpers from typed Elixir | `use RustQ.Meta` and `defrust` |
| Integrate an existing or precompiled crate | `RustQ.Native, build: false, load: false` |
| Read callable metadata from real Rust | `rust_sources`, `rust_packages`, and `RustQ.Syn` |
| Generate declarations from schemas | RustQ AST builders and ordinary Elixir macros |
| Keep generated Rust checked in | `rustq.exs` and `mix rustq.gen --check` |
| Generate around substantial handwritten Rust | parseable `.rs` templates and structural splices |

Rusty-Elixir is intentionally Elixir-shaped rather than fake Rust syntax. When a
construct cannot be expressed honestly in Elixir, use RustQ AST. Raw Rust tokens
are the final, local escape hatch—not the default authoring style.

## Documentation

- [Zero-handwritten-Rust NIFs](https://rustq.hexdocs.pm/zero-rust-nifs.html) —
  `RustQ.Native`, `defnif`, codecs, resources, scheduling, and existing crates.
- [Using RustQ Well](https://rustq.hexdocs.pm/using-rustq-well.html) — inference,
  Rusty-Elixir conventions, metadata, macros, AST, and migration guidance.
- [Generating Rust](https://rustq.hexdocs.pm/generating-rust.html) —
  `rustq.exs`, templates, placeholders, AST builders, splices, and validation.
- [Generating Rustler Boundaries](https://rustq.hexdocs.pm/rustler-generation.html)
  — atoms, term codecs, NIF wrappers, and structural Rustler helpers.
- [Designing RustQ Generators](https://rustq.hexdocs.pm/designing-generators.html)
  — project layout and maintainable generator architecture.
- [RustQ 1.x Compatibility Policy](https://rustq.hexdocs.pm/compatibility.html) —
  the public API and generated-code stability contract.
- [API reference](https://rustq.hexdocs.pm/api-reference.html) — public modules,
  functions, macros, and AST nodes.

## Agent skill

RustQ ships [`SKILL.md`](SKILL.md), an operational guide for coding agents that
work on RustQ-powered bridges and generators. Give it to an agent before it
writes generated Rust; it captures the inference-first, AST-first authoring
order and the important escape boundaries.

## Development

```bash
mix deps.get
mix ci
```

## License

MIT
