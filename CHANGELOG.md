# Changelog

## Unreleased

### Added

- `map_size` of a `HashMap`, `MapSet.size`, and `length` are Rust's `len()`,
  a `usize` where one is expected; so is arithmetic on them there.
- `Enum.empty?/1` and comparing with `[]` or `%{}` are `is_empty()`.
- `%{}` and `%{key => value}` build a `HashMap` or `BTreeMap` where one is
  expected.
- A generator over a map or set behind a reference iterates it by reference,
  copying copy keys and values and borrowing the rest.
- `first..last//step` with a positive literal step counts up between dynamic
  bounds, as Rust's `first..=last` does.
- `Enum.sort/1` sorts booleans, strings, and tuples as well as integers.
- A generator over a map or set is typed, map and set specs keep their key and
  value types, and an Elixir integer bound with `=` takes the integer type its
  later uses need.
- `%{}` where a reference to a map is expected builds one and borrows it, and a
  map key of unknown type is borrowed.
- A closure that only calls a function with its argument is that function.
- An interpolated string is `format!` of its parts, and a `for ... reduce:`
  over several generators or filters reduces the comprehension of the
  variables its clauses use.
- `MapSet.new()` where a reference to a set is expected is borrowed, a
  fallible list concatenated propagates its error, and cloning a reference to
  a reference clones the value.
- `List.replace_at/3` computes the new item, then sets it in place, leaving the
  list as it is for an index past its end.
- `left ++ right` concatenates lists, growing `left` in place at its last use:
  `list ++ [item]` pushes, and `list ++ other` extends.
- A comprehension's type follows all its generators, `{:some, value}` and
  `{:ok, value}` patterns included, and a tuple bound with `=` types each
  variable.
- A `Vec` read from Rust source is a list, as one a spec names is.
- A `case`, `if`, `cond`, or block has the type of its first branch whose type
  is known, and a block's bindings are typed in order.
- `Enum.map(list, fn item -> item.clone() end)` is `cloned()` over a list of
  references, and the list itself otherwise.
- `Enum.reduce/3` builds its accumulator as the expected type, `%{}` and `[]`
  included, and has the reducer's type when its initial value has none.
- Indexing a map or list, and the module's own aliases named inside other
  types, are typed; a `Vec`, reference, or tuple rebuilt from Rust syntax keeps
  its kind; an alias of a copy type is copied.
- Copy items a slice lends are copied out for any use, a tuple pattern on a
  reference binds references to its elements, Elixir's integer compares in
  the Rust integer type of the other side, and a function argument that
  cannot fail to match is bound with `=` rather than matched.
- A variable put into a new list or pushed while still in use is copied, and
  `Map.get/3` with an empty default is `unwrap_or_default()`.
- `String.downcase/1` and `String.upcase/1` lower to `to_lowercase()` and
  `to_uppercase()`, and membership among literals, as `word in ["no", "off"]`,
  asks an array, looking a `String` up as a `&str`.
- A comprehension over a list of tuples still in use iterates it by
  reference, copying copy elements rather than cloning every item.

### Fixed

- What indexing reaches is never taken from its collection; it is copied.
- Taking a value behind a reference copies it, so an update to a borrowed set
  never changes the set it was given.
- A list matched against a list pattern binds its items by reference, and a
  slice index read from one is copied.
- `Map.update/4` matches the present value, so the function and the default
  may each take what they use.
- A map is indexed by a borrowed key.
- Collecting into a slice argument collects a `Vec` and borrows it.
- `Enum.concat/2` and `Enum.zip/2` take a list only at its last use, and copy
  from one the other side borrows.
- An iterator collected into a list and iterated again is iterated as it is.
- A generator over one value computes it before the item moves into the pair.
- A string literal key is looked up as the `&str` it is, and comparing a string
  with `""` asks whether it is empty.
- Operators read borrowed copy values a pattern binds: a comparison derefs the
  borrowed side, `and`/`or` and `if` take booleans, and an atom compared with
  an enum is that enum's variant.
- A count passed where a `u32` or another integer is expected is cast to it.
- `List.first/1` and `List.last/1` on an iterator collected into a list take
  from the iterator.

## 1.0.0-rc.19 - 2026-10-26

### Added

- What std's methods return is known wherever the receiver's own type
  parameters decide it: `name.as_ref()` on an `&Option<String>` is an
  `Option<&String>`, and `list.first()` an `Option<&T>` of its items.
  `Type.substitute/2` binds a type's parameters.
- A list literal whose items share a type is a list of that type.

### Fixed

- `Enum.at` on a pipeline stage is the iterator's `nth`, collecting no list.
- A filter over copied tuples matches each by reference, as `|&(set, field)|`.
- `Enum.count`, `length`, and `byte_size` stay `usize` where one is expected.
- A function a `defrustmacro` defines can name the module's own types in its
  spec, as a `defrust` can.
- A fallible call used as the receiver of a method its result lacks, as
  `decoder.read_bool().encode(env)`, propagates its error first.
- A loop over a slice, or a list behind a reference, reads each item by
  reference, so passing one on where a reference is expected borrows it once.

## 1.0.0-rc.18 - 2026-10-26

### Added

- A pipeline of `Enum` stages runs as one Rust iterator chain:
  `list |> Enum.map(f) |> Enum.find(p)` is `.map(f).find(p)`, with no list
  collected between them, and `Enum.count/1` on a stage counts as it goes.
- `mix rustq.std` also derives what std's methods on strings, characters,
  lists, maps, sets, and options return where the receiver's type parameters
  do not matter, so `name.len()` is a `usize` and `name.trim()` a `&str`.
- A comprehension's type is the list, map, or set it collects its body's
  values into, and a block of expressions lowers wherever an expression does.

### Changed

- Whether a value may be taken is decided for each use of it: a pass over the
  body records what is still in use after every variable occurrence, as
  Elixir scopes it, so a list used again later in the same expression, as
  `{Map.put(scores, name, 1), scores}`, is copied. A parameter is `mut` where
  the lowered Rust changes it in place.
- `Map.new`, `MapSet.new`, `Enum.into` into an empty collection, `group_by`,
  `uniq`, and generators over `Enum.with_index` are rewritten into other
  Rusty-Elixir before lowering, by `RustQ.Meta.Desugar`.
- Pattern, comprehension, path, and mutability lowering are their own modules
  beside `RustQ.Meta.Lower`.
- Each Elixir module's lowering implements
  `RustQ.Meta.Lower.Stdlib.Lowering`, whose `use` imports the helpers they
  share, and a call goes to the lowering named after its module. Lowering
  builds Rust with `RustQ.Rust.AST.Builder`, whose `expr/1` now accepts every
  RustQ AST node.

## 1.0.0-rc.17 - 2026-10-25

### Added

- A module's `defrustmod` mappings come with it under the alias naming it, and
  `defrustmod __MODULE__, as: [...]` maps the module itself, so a library maps
  the Rust modules its generated code defines once for every module using it.
- `MapSet` lowers on `HashSet`s, `MapSet.t(item)` is a `HashSet`, and `Map`
  lowers on `HashMap`s as well as structs: `get`, `fetch!`, `has_key?`, `put`,
  `delete`, `merge`, `update/4`, `keys`, `values`, `to_list`, and `new`, and
  `MapSet.new`, `put`, `delete`, `member?`, `union`, `difference`,
  `intersection`, `subset?`, `disjoint?`, `size`, and `to_list`. Updates take
  the collection only at its last use.
- `Enum.into`, `group_by`, `with_index`, `find_index`, `find_value`,
  `reduce_while`, `sort_by`, `max_by`, `min_by`, `max`, `min` (with an empty
  fallback), `uniq`, `uniq_by`, `dedup`, `split_with`, `at`, `slice`,
  `take_while`, `drop_while`, `zip_with`, `chunk_every`, `join`, and
  `map_join`. A comprehension over `Enum.with_index(list)` enumerates the list
  in place, and `into: HashMap.new()` or `MapSet.new()` collects into that
  collection where no type is expected.
- Rebinding a list, map, or set to its update, as `scores = Map.put(scores,
  name, 1)` or `layers = Enum.sort_by(layers, ...)`, changes it in place:
  `scores.insert(name, 1);`.
- A comprehension generator over one value, as
  `{:some, id} <- [record_id(record)]`, matches the value beside the item
  instead of iterating a list made for it.

### Changed

- `Enum` functions take an owned list only at its last use. A list used
  afterwards, by the call's closure, or by a value built from it is borrowed,
  so code using the list again compiles. Questions such as `any?` and `all?`
  always borrow, items kept from a borrowed list are cloned, and numbers and
  atoms are copied out.
- A new value such as `HashSet.new()` passed where a reference is expected is
  borrowed.
- A list reached through a reference, as `binding.superseded` for a borrowed
  `binding`, is never taken: `Enum` borrows it and a comprehension copies its
  items, as a comprehension also does for an owned list still in use.
- `Enum.filter/2`, `reject/2`, `find`, and `count/2` lower to Rust's `filter`
  and `find`, as clippy prefers to `filter_map` returning the item; a number or
  atom item is matched as `|&value|`. `Enum` iterates slices with `iter()`.
  `RustQ.Rust.AST.PatRef` renders `&pattern`.

## 1.0.0-rc.16 - 2026-10-25

### Added

- A RustQ module provides the `.rs` file named as its own file is in
  `templates/` beside it, such as `templates/runtime.rs` for `runtime.ex`: Rust
  it emits as it is, like a runtime a library ships. Its functions, methods, and types join the module's
  exports, each type as an Elixir type, and `__rustq_items__/0` and
  `__rustq_source__/0` emit it. `use RustQ.Meta, provides: [...]` names other
  files, relative to the module's file. A library no longer needs to publish
  where its Rust files are.
- A RustQ module named through `alias` in a spec, a type, or a `defrust` body is
  imported as `callable_modules` imports one, and calling its Rust function as
  `Module.function(...)` lowers to the function's call. Other aliases remain
  Rust paths.

## 1.0.0-rc.15 - 2026-10-24

### Added

- `match?(pattern, value)` lowers to a `match` answering whether the value
  matches, so `defrust` bodies need not spell it as a `case` returning `true`
  and `false`.

## 1.0.0-rc.14 - 2026-10-23

### Added

- `RustQ.Meta.AST.macro_call!/3` takes RustQ AST for `:expr` and `:ty`
  captures and renders it, so a generator need not write Rust source strings
  for them.

### Changed

- `use RustQ.Meta, rust_sources: ...` evaluates its paths when the module
  compiles, so they can come from a module attribute or a function, such as one
  returning the path of a Rust source a library ships. Relative paths are still
  relative to the working directory, which a library loaded from another
  project cannot rely on.
- `defrustmacro` repetition rows separate their captures with commas, in the
  pattern and in the calls `RustQ.Meta.AST.macro_call!/3` builds, for every
  row. RustQ used to lay out a few row shapes, written for kiwi_codec, with
  `=>` and `:`, and fall back to spaces otherwise, which `expr` captures cannot
  be followed by.

- `RustQ.Rustler.Term`'s struct helpers no longer name rustler's raw term
  type, which rustler 0.39 changed from `rustler::wrapper::NIF_TERM` to
  `rustler::sys::ErlNifTerm`. `cached_struct_keys` caches `Atom`s,
  `default_struct_values` returns `Vec<Term>`, and
  `make_struct_from_nif_term_arrays` is `make_struct_from_arrays`, taking atom
  keys and term values. The same Rust builds on rustler 0.37 to 0.39.
- `RustQ.Native` crates depend on rustler 0.39 by default, and
  `mix rustq.templates.check` and the suite's generated-Rust check build
  against it.

### Removed

- `RustQ.Rustler.Nif.raw_term_builders/1`. Its helpers called
  `rustler::wrapper`, which rustler 0.39 removed;
  `RustQ.Rustler.Term.builders/1` builds the same maps and structs from terms.

### Fixed

- `assign!(index(values, i), call())` propagates a fallible call with `?` when
  the element type is known, as a `let` with a known type does, and makes an
  owned `values` argument `mut`. The Rust assigned the `Result` and changed an
  immutable argument.
- A `defrust` inside an item `defrustmacro` keeps its plain arguments plain.
  Every argument used to be written as a macro variable, `$offset`, which the
  body then referred to as `offset`.
- Calling a function a `defrustmacro` names with an `:ident` capture calls
  `$inner(...)` rather than a function literally named `inner`.

## 1.0.0-rc.13 - 2026-10-23

### Added

- A type declared twice in a module is a `:duplicate_type` diagnostic naming
  both lines. RustQ reads types before Elixir rejects the duplicate, and used
  to follow the later declaration silently; types read from source with
  `RustQ.Spec` were never checked at all.
- `RustQ.Spec.declarations/1` takes declarations' lines from
  `quote location: :keep` as well as from parsed source.

### Changed

- A typespec RustQ has no Rust type for, such as `pid()`, `keyword()`,
  `map()`, a bare `nil`, or a literal `1` or `1..10`, is an `:unsupported_type`
  diagnostic suggesting a `RustQ.Type` spelling. It used to become a Rust type
  named after it, which never compiled. `any()` is `Term`, as `term()` is.
- `byte()` is `u8`, `non_neg_integer()` and `pos_integer()` are `u64`, and
  `char()` is `u32`, since it includes surrogate code points Rust's `char`
  cannot hold. `pos_integer()` admits zero, and rustler's `u8` decoder truncates
  out-of-range integers rather than rejecting them.
- Which words are Rust keywords, written as raw identifiers, comes from syn
  rather than a list kept in RustQ, in the native and the text renderer alike.

### Fixed

- A function returning `R.nif_result(t)` returns a plain value as `Ok(value)`,
  as the NIF returns that value in Elixir. Its Rust returned the bare value,
  which did not compile; a plain value returned where an `R.result` is expected
  is now a diagnostic asking for `{:ok, value}`.
- A tail `decode_as!` in such a function is its `decode`, without the `?` that
  made it not compile.
- `:ok` returned where an atom is expected is the atom, and `Ok(())` for any
  result carrying nothing; it used to be `()` wherever the type was not
  `NifResult<()>`.
- `{:some, value}` and `:none` where an option is expected are `Some(value)`
  and `None`, as patterns read them; `{:some, 12.0}` used to be a tuple.
- A function returning a variable typed as a 3-tuple returned the variable's
  Elixir AST as a tuple of atoms.
- `true` and `false` render as raw identifiers wherever a name goes, and
  `macro_rules!` names and grouped `use` names are escaped as other names are.
- Rendering a node on its own escapes keywords in variables, fields, methods,
  closure arguments, patterns, and atom names, as rendering it inside an item
  does.
- A name Rust cannot use as an identifier, such as a field named `self`, is a
  diagnostic carrying syn's message. It used to render invalid Rust, fail with
  "argument error", or crash the native renderer.
- Rendered Rust is checked to parse before it is returned.
- `RustQ.Rust.AST.Builder.expr(true)` builds the literal, not a variable named
  `true`.
- A `RustQ.Native` crate using `%{key => value}` or `HashMap.t` in a NIF
  compiles; it imports `HashMap`.
- A public `R.enum` type crosses the NIF boundary as Elixir writes it, as
  `{:circle, 1.0}` or `:empty`, through `rustler::NifTaggedEnum`. It had no
  codec, so a NIF taking or returning one did not compile.
- A `defnif` whose spec returns `binary()` returns an Elixir binary. Its
  bytes are a `Vec<u8>` in Rust, which rustler sends as a list, so the NIF now
  wraps a `*_rustq_binary_impl` function and copies its bytes into a new
  binary. A `binary()` nested in an argument or result still crosses as a list
  of bytes.
- `gen`, which the 2024 edition reserves, renders as a raw identifier.
- A path segment named `try`, or a variable named `break`, `continue`,
  `return`, or `yield`, renders raw. It used to render as the keyword, which
  parses but does not name the variable.

## 1.0.0-rc.12 - 2026-10-22

### Added

- Lower comprehensions with several generators, filters, and patterns that can
  fail to match. As a value, a comprehension becomes an iterator pipeline that
  collects into the expected type, so `into:` works by the target type; run for
  its effects, it becomes nested `for` loops with `if let` and `if`.
- Lower `&fun/1` captures in any expression, not only inside `Enum` calls, and
  `&(&1 + 1)` shorthand to a closure, including as an `Enum` mapper.
- Lower `container[key]` to Rust indexing, borrowing the key for a map, also
  through a reference to one.
- A spec's `%{key => value}` with one key type is a `HashMap`, as
  `HashMap.t(key, value)` is.
- Match constants such as `Kind.PLAIN` in patterns, resolved through the
  module's Rust module aliases, and `true` or `false` in `with` clauses.
- Add `R.ref/2` and `R.mut_ref/2` for references with a named lifetime, as in
  `R.ref(Record.t(), R.lifetime(:a))`, which a function returning a reference
  borrowed from one of several reference arguments needs.
- Add `R.hashable(type)` for a declared struct or enum that also derives
  `PartialEq`, `Eq`, and `Hash`, so it can key a map or set.
- Build and match `R.enum` values with tagged tuples, as in Elixir:
  `{:float, value}` is `Literal::Float(value)` and `:missing` is
  `Literal::Missing` wherever the enum is expected or matched, including
  through a reference and inside a type that refers to itself.
- Generate Rust-only types from `@typep`: the struct, enum, or alias without
  the term decoder a `@type` gets, so it may hold values without a term codec.
- Lower `%{value | field: new}` on a struct to Rust's struct update syntax,
  `Struct { field: new, ..value }`, including on the items a comprehension or
  `Enum` function's closure is given; a struct a closure captures is cloned.
- Closures that a comprehension or `Enum.map`, `flat_map`, `each`, `reduce`,
  `any?`, or `all?` gives a typed list's items know their type.
- A later generator over a list from outside the comprehension copies its
  items, so `for x <- xs, y <- ys` compiles without cloning `ys` by hand.
- Add `R.slice(type, R.lifetime(:a))` for a slice with a named lifetime.
- An atom where an atom-union type such as `:small | :large` is expected names
  the enum variant, as patterns already did, including fields of a
  `struct_literal` whose struct the module declares.
- A module may use the types its `callable_modules` declare, written remotely
  as `Other.tree()` since Elixir checks local types; they keep their single
  Rust declaration in the module that declares them.
- `RustQ.Syn` describes traits, as `RustQ.Syn.Trait` with their associated types
  and methods, and `RustQ.Syn.Index.traits/1` lists them. Impls carry their
  type parameters' trait bounds and the associated types they define; methods
  carry their attributes and type parameters' bounds. Impls also carry their
  trait's structured path as `trait_ast`, and `negative` marks `impl !Trait`. `RustQ.Syn.parse(source, unstable: true)` reads source that
  uses unstable syntax which does not change an item's signature, as the Rust
  standard library does.

### Changed

- Which std methods mutate their receiver, return an iterator or an option,
  belong to `Option` and `Result`, or belong to std collections is derived from
  the Rust standard library's source rather than listed by hand, so lowering
  knows every stable method, such as `push_back`, `retain_mut`, or `nth`.
- A callable's arguments are `RustQ.Binding.Callable.Arg` structs rather than
  bare maps with the same keys.
- Piping into a function the module can call passes the value as its first
  argument, as in Elixir. It used to call a method of that name on the value.
- An Elixir predicate such as `live?` names the Rust function `live`; a module
  defining both is rejected.
- Document every module and function that was hidden from the API reference.
  Lowering, code generation, native build, and tooling internals are grouped
  as such, and the user-facing groups list only user-facing modules.
- Stub modules `RustQ.Rustler.Nif` generates carry a moduledoc, so checked-in
  generated stubs need regenerating.
- The API reference leaves out the tools in `dev/` for working on RustQ itself,
  which the package does not ship.

### Fixed

- Elements of a tuple pattern are full patterns, so `{{:some, Kind.PLAIN}, _}`
  matches the constant inside the option.
- A pipe into a name the module does not define lowers as that method call,
  with the same argument types and borrows; a `let` bound to a `collect()`
  states what it collects into, a `Vec` unless known.
- A binding used through option methods such as `is_some` keeps its option
  type, a vector's items are not taken for its success type, and methods
  every collection has, such as `is_empty`, no longer type a binding as
  whichever source type also defines them. `clone` of a borrowed struct and
  `to_vec` are typed.
- `ok(value)` lowers the value as the expected success type, so `ok(:ok)` is
  `Ok(())`; tuple literals are typed when their elements are, so atom and
  constant patterns match inside them.
- Mark `mut` a tuple-destructured binding that changes, and an owned argument
  changed through a field or borrowed with `mut_ref`. A field named like a
  changing method, such as `layer.swap`, does not mark its struct `mut`.
- Pushing a call that fails as the function does onto a vector of unknown
  items propagates it; collecting where a slice is expected collects into a
  vector and borrows it; an option or result binding nothing downstream
  unwraps keeps its type.
- Write the Rust Clippy expects: a comprehension over `values.iter()` does not
  call `into_iter()` again, one that clones each item is `cloned()`,
  `into_iter()` on a borrowed collection is `iter()`, and a statement `case`
  whose other branch does nothing is an `if let`.
- A closure `Option::map` or `and_then` takes lowers its body as the expected
  option's value, so tagged tuples and atoms inside it name variants; an option
  a closure maps, items collected, or an iterator's `next` is not wrapped in a
  second `Some`. `or`, `or_else`, `as_slice` are typed.
- Patterns in `with`, inside `{:some, _}`, and on slices take the type of what
  they match, and a list pattern on a value of unknown type is a slice pattern.
- Inference reads a struct literal's fields as the types the struct declares,
  ignores uses after a pattern binds the same name again, and a comprehension
  ignores item variables its body does not use.
- A failed native render names atoms matched inside patterns no type resolved.
- A borrowed number, boolean, or tuple of them passed where the value is
  expected is copied out with `*`, and arithmetic on borrowed numbers is typed
  as a number; `ref(value)` is typed as a reference, and `try_fold` in an
  option-returning position is not wrapped in `Some`.
- A comprehension whose collection type is known lowers its body as the item
  type, so tagged tuples and atoms in it name variants, and `extend` on a
  vector takes items of its type.
- A `with` run for its effects whose `else` does nothing lowers to nested
  `if let`s, with `true <- condition` as an `if`; variables a slice pattern
  binds are typed as references to its elements.
- Keep the grouping of nested operators: `a and (b or c)` rendered as
  `a && b || c`, and `not (a or b)` as `!a || b`. Operands are parenthesized
  by Rust's precedence.
- A `cond` run for its effects lowers to `if` statements, and a comprehension
  bound in a statement states what it collects into, a `Vec` unless known.
- An explicitly borrowed argument is not borrowed again, and a method that
  changes its receiver marks it `mut` wherever it is called.
- Render words Rust reserves for future use, such as `override` and `yield`, as
  raw identifiers, including function and closure arguments and local calls.
- Compare two options or results without propagating either side, never
  propagate literals, and type arithmetic on a propagated option as its value,
  so `some(value + 1)` no longer wraps the sum in a second `?`.
- Parenthesize a `?` applied to a compound expression; it used to bind only to
  the last operand.
- Mark a variable `mut` when a statement-level method chain starting with a
  method that changes it, such as `map.entry(key).or_default().push(value)`,
  uses it, and a closure argument its body changes, such as a fold accumulator.
  An empty map or set bound with a known type states it, as Rust cannot infer
  its value type through `entry(key).or_default()`.
- Lower a `with` whose `else` is a lone catch-all to that fallback arm, rather
  than a single-arm match on the unmatched value, and a borrowed list literal
  to a borrowed array rather than a vector built for the borrow.
- Patterns of unknown type drop the old types of the names they rebind, and a
  `with` clause takes the type of a plain variable it matches, so a rebound
  value is no longer propagated as the option it came from.
- A `with` without `else` passes an unmatched `{:error, _}` or `nil` on as
  the function's own `Err` or `None`, as Elixir returns the unmatched value.
- Never propagate with `?` in a function or closure returning a plain value
  such as a vector; the value stays wrapped there.
- Type `get` on maps and on borrowed vectors, `and_then`, `copied`, `cloned`,
  and methods reached through a pipe, so an option they return is no longer
  wrapped in a second `Some`.
- A function returning nothing runs its last expression as a statement, so a
  trailing `if` or `for` no longer becomes a value such as a collected vector.
- `ref([])` where a slice is expected borrows an empty array.
- A type that refers to itself, such as a tree whose children are trees, names
  its Rust type in its own fields.
- Mark an owned argument `mut` for any method that changes it in place, such
  as `retain` or `sort`, not only `push` and `insert`.

## 1.0.0-rc.11 - 2026-09-30

### Added

- Describe enum variant payloads in `RustQ.Syn.Enum.variant_shapes`, a list of
  `RustQ.Syn.Variant` structs with the variant name, its kind (`:unit`,
  `:tuple`, or `:named`), its fields, and its doc comments. `variants` still
  lists variant names.
- Report `lifetimes` and `type_parameters` for `RustQ.Syn.Struct` and
  `RustQ.Syn.Enum`, matching the existing function and method metadata.
- Add `RustQ.Rustler.Term.encoders_from_source/3` and
  `encoder_atoms_from_source/3`, which build `Term` encoder functions and their
  atom declarations for structs and enums read from Rust source. They support
  types owned by another crate and without `serde`. Any reachable type that is
  not indexed, a wrapper, a scalar, or mapped as external fails generation with
  a list of the unmapped types, as does a variant tag that would replace a
  payload field with the same key. Per-type policy covers excluded fields, key
  and variant renames, `with:` helpers, and `transparent: true` structs.
- Add `RustQ.Syn.Index.structs/1`, `struct/2`, and `struct!/2`.
- Add `RustQ.Rust.AST.PatternBuilder.tuple/1`.

### Fixed

- Render Rust keywords used as field names, struct literal and struct pattern
  fields, and macro item arguments as raw identifiers (`r#type`). Field access
  such as `value.type` previously failed to render.
- Type a literal atom such as `:if_node` in a typespec as `Atom`, like a union
  of atoms. It was emitted as a Rust type named after the atom, which does not
  compile.

## 1.0.0-rc.10 - 2026-09-28

### Fixed

- Resolve local type alias references regardless of declaration order. An
  alias referenced inside a list, tuple, or map value from an alias that sorts
  before it, such as `[plugin()]` in `lint_input`, was emitted as the raw
  Elixir name (`Vec<plugin>`) instead of its Rust type (`Vec<Plugin>`).
- Stop passing `fast_path:` to JSONCodec, which json_codec 0.3 deprecates, so
  RustQ compiles without warnings on json_codec 0.1 through 0.3.

## 1.0.0-rc.9 - 2026-09-06

### Added

- Support named fields and attributes on Rust enum variants, and attributes on
  match arms, enabling feature-gated event declarations and dispatch.
- Add explicit move captures with `move(fn ... end)`, tuple-pattern closure
  parameters, and structural closure arguments with optional Rust types.
- Add `R.impl` for native callable types using ordinary Elixir function
  signatures, with `:fn`, `:fn_mut`, and `:fn_once` kinds, additional traits,
  and explicit lifetime bounds.
- Preserve foreign callable-trait parameter and return types, and specialize
  supported generic method arguments from known receiver and argument types.
- Expand supported source-defined Rust type aliases for receiver inference,
  including generic aliases and grouped imports. Resolve known standard-library
  shared pointers, mutex lock results, and guard receivers without guessing
  from unrelated method names.

### Fixed

- Render matching struct-field bindings in shorthand form for Clippy-clean
  generated patterns while preserving explicit renamed bindings.
- Reject enum variants that mix tuple and named fields.
- Preserve reference and unary-expression precedence in method receivers.
- Infer borrows for dereferenced values and supported `String` and `Vec` clone
  results, including expressions derived from typed callback parameters.
- Keep closure parameter types scoped to the callback instead of inheriting
  shadowed outer-variable types.
- Omit redundant unit returns, use struct-expression field shorthand, and
  simplify supported ignored-error result matches for Clippy-clean output.
- Avoid unnecessary mutable bindings for local references while preserving
  explicit mutation requirements.
- Respect generic-parameter shadowing during alias expansion, refresh aliases
  after source edits, and diagnose conflicting generic substitutions.
- Reject unsupported lifetime-alias expansion and inconsistent specialization
  of opaque foreign trait bounds rather than silently changing their meaning.
  Defer unsupported nested or ambiguous alias diagnostics until expansion
  requests them.

## 1.0.0-rc.8 - 2026-09-06

### Added

- Add `@cfg` for conditional Rust helper, method, and NIF implementations with
  shared signatures and separate clause groups.
- Support nested attribute metadata, including `not`, `all`, and `any`
  predicates, with typed path, name/value, and list representations.
- Select conditional functions with `RustQ.Meta.AST.function!/3` and a `:cfg`
  option.

### Changed

- Reject ambiguous function selectors instead of choosing the first conditional
  implementation.
- Diagnose stacked or dangling conditions, duplicate conditions, mixed
  unconditional/conditional definitions, and inconsistent NIF scheduling policies.

### Fixed

- Preserve authored receiver names and lexical shadowing in `defrustimpl`
  methods through a local binding to the Rust receiver.
- Gate generated NIF result codecs and implementation helpers consistently
  with their conditional entrypoints while retaining one Elixir export.

## 1.0.0-rc.7 - 2026-09-06

### Changed

- Reject integer operands for `/` with an actionable diagnostic; use explicit
  floating-point conversion when floating-point division is intended.
- Validate generated Cargo dependency names, options, and duplicates, and
  serialize manifests with a TOML encoder for correct string escaping.

### Fixed

- Load generated native libraries correctly on macOS.
- Preserve native result types through NIF boundary encoding, recursive calls,
  composed calls, closures, and named captures; diagnose generated-name conflicts.
- Preserve expected result types in `cond` branches and typed `Enum.map` closures.
- Resolve local type aliases in decoding expressions and external struct
  constructor paths consistently with their remote typespecs.
- Infer the decoded value type for return-position `.decode()` and optional
  return types for checked integer arithmetic methods.
- Preserve argument evaluation and infer result propagation for shape queries.
- Refresh callable metadata after provider recompilation and source changes,
  including same-size edits with unchanged timestamps.
- Render nested conditionals as `else if` where appropriate for Clippy-clean output.

### Security

- Update maintainer HTTP dependencies to versions without the reported security
  advisories and remove unused dependency lock entries.

## v1.0.0-rc.6 - 2026-07-27

- Infer mutable owned Rust arguments from mutating collection method calls and
  render them directly as `mut` parameters, including metadata-backed mutable
  receivers and supported `Vec` and set/map insertion methods.

## v1.0.0-rc.5 - 2026-07-27

- Add focused `RustQ.Meta.AST` selectors for generated Rust items, type items,
  enums, structs, and inherent or trait implementation blocks.

## v1.0.0-rc.4 - 2026-07-27

- Add `defrustimpl` for generating inherent and trait Rust implementation
  methods directly from typed Rusty-Elixir, including `&self` and `&mut self`
  receiver inference and implementation visibility, attributes, and lifetimes.

## v1.0.0-rc.3 - 2026-07-17

- Generate optional Rustler term filters with typed `Option::filter` calls for
  compatibility with Rust 1.97 Clippy.
- Highlight fenced Rust examples in generated HexDocs.

## v1.0.0-rc.2 - 2026-07-16

- Add composable `RustQ.Test.rust_source!/1,2` and `nif_exported?/3` helpers
  that preserve ordinary ExUnit assertions and diffs; reorganize the suite
  around focused source values, parameterized schema/corpus cases, compiled
  support fixtures, and ExUnit-managed temporary directories.
- Decode precise-capturing `impl Trait + use<'a>` bounds without relying on
  pre-existing runtime atoms, as exercised by current `skia-safe` metadata.
- Funnel compiled `defrust` AST access and internal rendering through the
  documented `RustQ.Meta.AST` and `RustQ.Rust` boundaries.
- Preserve inferred tuple types as structural `RustQ.Rust.AST.TypeTuple` nodes
  instead of raw rendered type strings.
- Preserve imported Rust reference lifetimes and fixed-array lengths, lowering
  them through structural `TypeRef`, `TypeArray`, and `TypePath` nodes.
- Add structural bare-function types with bound lifetimes, unsafe and ABI
  qualifiers, named input metadata, variadics, and return types.
- Preserve ordered Rust path generic arguments and `impl Trait` bounds in Syn
  metadata, and lower complete bound lists through structural `TypeImplTrait`.
- Document `defnif` normal, dirty CPU, and dirty IO scheduler policy and the
  preferred `@nif schedule: :dirty_cpu | :dirty_io` spelling.
- Replace the README reference manual with a focused project overview and move
  template, AST, splice, metadata, and validation details into a generation guide.
- Lower supported remote calls in Elixir pipelines and carry expected collection
  types through materialized Enum stages, preserving eager semantics while
  avoiding ambiguous Rust `collect()` inference.

## v1.0.0-rc.1 - 2026-07-16

- Define the RustQ 1.x compatibility contract and ship the policy with the
  package, HexDocs, and agent skill.
- Add `RustQ.Native`, public `defnif`, private `defrustp`, generated Cargo
  crates, native loading, Cargo dependency metadata, and dirty-scheduler
  normalization for zero-handwritten-bridge-Rust NIFs.
- Derive directional Rustler boundaries for scalars, strings, binaries, tuples,
  lists, options, tagged results, typed maps, Elixir structs and exceptions,
  structural unions, unit enums, and explicitly declared resources.
- Expand Rusty-Elixir lowering with multiple clauses, recursion, list/map/struct
  patterns, guards, comprehensions, and structural slice-pattern AST support;
  normalize semantics-preserving Kernel, Enum, List, typed Map, String, Tuple,
  and Range calls through focused hidden lowerers with call-specific typing.
- Add external/precompiled-crate native preparation through
  `use RustQ.Native, build: false, load: false`, with public
  `RustQ.Native.items/1` and implicit `nif_env/0` injection that preserves BEAM
  arity.
- Add packaged `RustQ.Test` ExUnit assertions for focused `defrust` source,
  `defnif` exports/attributes, and generated Rust validity.
- Expose all compiled `defrust` function AST nodes through the documented
  `RustQ.Meta.AST.functions/1` generator boundary.
- Validate documented public APIs, package contents, checked generation, and a
  formatted, Clippy-clean zero-Rust native crate through structured external
  consumer fixtures containing no checked-in Rust or Cargo files.

## v0.11.1 - 2026-07-14

- Lower named `Enum.map/2` function captures and multi-statement closure bodies,
  and dogfood them for generated native AST collection decoders.
- Generate Rustler term decoders structurally, including cached struct keys, and
  add an AST-backed unsafe block for isolated low-level Rustler operations.

## v0.11.0 - 2026-07-13

- Require structural Rust type nodes at the native rendering boundary, normalize
  builder type inputs, and add structural tuple types.
- Support multiple lifetimes on Rust struct AST nodes, hide the internal AST
  renderer, and remove duplicate simple-item builder delegates.
- Validate atom-backed Rust identifiers and avoid callable metadata cache locks
  during parallel compilation.

## v0.10.0 - 2026-07-10

- Make `RustQ.Rust.AST` the canonical generated-Rust representation, including
  source-derived NIF wrappers with multiple lifetimes, and remove the duplicate
  legacy Rust builder model.
- Reorganize Rustler generation into focused `Nif`, `Term`, `Atom`, `Opts`,
  `Resource`, and `Schema` APIs with concise wrapper, function-metadata, stub,
  and encoder naming.
- Simplify generator manifests, template rendering, metadata selection, and
  file-spec APIs; hide implementation modules and document the public API by
  responsibility.

## v0.9.11 - 2026-07-10

- Discover Rustler atom references through a configurable Rust module name,
  including references nested in macro token trees.

## v0.9.10 - 2026-07-10

- Preserve explicit nested `Option` constructors and infer `Option::map(Some)`
  without adding extra wrappers or propagation.
- Add a source-generated optional-string map decoder and emit zero-arity Elixir
  NIF stubs without parentheses.

## v0.9.9 - 2026-07-10

- Preserve nested wrapper tuple binding types and lexical pre-shadow types so
  downstream inference does not add propagation to infallible values.

## v0.9.8 - 2026-07-10

- Select map-backed Rust struct items from Rusty-Elixir `@type` metadata with
  configurable derives, attributes, struct visibility, and field visibility.

## v0.9.7 - 2026-07-10

- Add structural schema field and shorthand-field splices for projection-driven
  Rust struct declarations and literals.

## v0.9.6 - 2026-07-10

- Generate one Elixir NIF stub module from mixed Rust source metadata and RustQ
  AST functions, including automatic Rustler `Env` exclusion.

## v0.9.5 - 2026-07-10

- Preserve no-parentheses function-pointer field access in expected-type
  positions instead of lowering fields named `decode` as generic Rustler method
  calls.

## v0.9.4 - 2026-07-10

- Add AST-backed Rustler term encoders with nested, conditional, optional,
  collection, adapter, helper, and fallback field projections.
- Add source-derived Rustler NIF wrappers and Elixir fallback stubs so one
  manifest and the handwritten Rust implementation signatures determine both
  sides of the boundary.
- Discover atom references inside Rust macro token trees and document stable,
  structural Rustler generation workflows.
- Add optional Rustler map decoders and improve option/method result inference.

## v0.9.3 - 2026-07-06

- Infer `Option<T>` author input for expected `Option<&T>` adapter arguments,
  including fallible `NifResult<Option<T>>` values passed to
  `impl Into<Option<&T>>` Rust methods.
- Preserve owned option locals while emitting `.as_ref()` at the eventual call
  site to avoid borrowing from temporaries.

## v0.9.2 - 2026-07-06

- Improve Rusty-Elixir propagation and borrow inference for fallible option
  cases, `some(...)`, `unwrap_or`, `decode_as!`, `map_get`, fallible reference
  access, list/slice arguments, loop bindings, and method arguments.
- Improve callable metadata lookup for qualified method receivers and add corpus
  coverage for `impl Into<Option<T>>` argument propagation.
- Refresh README, guide, skill, and module docs around inference-first authoring
  with less explicit `unwrap!`, `ref`, and `mut_ref` boilerplate.

## v0.9.1 - 2026-07-06

- Improve expected-input inference for callable arguments, including fallible
  `case` scrutinees, associated calls, and slice/`Vec` borrow adaptation.
- Add corpus coverage for semantic `defrustmacro` item calls and recent
  propagation/borrow inference regressions.

## v0.9.0 - 2026-07-06

This release is a large Rusty-Elixir self-hosting and downstream dogfooding
release. It expands structural Rust generation, improves type-driven lowering,
and fixes a major compile-time performance regression exposed by Skia dogfood.

### Added

- Add Rust type item generation from `@type` aliases, including type aliases,
  structs, enums, and Rust-only support records that do not force generated
  Rustler term decoders.
- Add `R.enum(...)` for explicit Rust enum type items and fix zero-arity type
  alias resolution for bare `@type name :: ...` declarations.
- Add structural `macro_rules!` AST support and native validation/rendering for
  macro variables, captures, repetitions, and macro repeat expressions.
- Add AST walking utilities for RustQ AST traversal and mutation analysis.
- Add golden corpus tooling for Rusty-Elixir lowering, with coverage reporting
  by category.
- Add semantic `enum_variant(Type, :variant, ...)` lowering for constructing
  Rust enum variants from Rusty-Elixir without token macros.
- Add semantic item-producing `defrustmacro` calls and macro item call support.
- Add `defrustmacro` support for compact `skip_fields` and sparse struct field
  descriptor row patterns.
- Add idiomatic Clippy lint paths for Rust-facing attributes, such as
  `@allow Clippy.redundant_field_names` rendering to
  `#[allow(clippy::redundant_field_names)]`.
- Add dev-only RustQ Reach smell checks and dogfood them in strict mode for raw
  Rust escapes, low-level Rusty-Elixir control flow, trivial `defrust` wrappers,
  and blockless `defrustmod` aliases.

### Changed

- Extend `defrustmacro` with identifier/literal captures, item-generating inner
  `defrust` bodies, multiple generated item bodies, and `repeat ... do`
  macro-template repetitions.
- Lower calls to known `defrustmacro` helpers as generated Rust macro
  invocations, and support remote Rust macro calls such as `Debug.trace!(value)`.
- Replace ad hoc macro metavariable spacing cleanup with structural macro repeat
  expression rendering.
- Remove the process dictionary from Rusty-Elixir lowering; lowering state is now
  threaded explicitly through expression, call-argument, alias, array,
  control-flow, return, and expected-expression lowering.
- Make context-aware expression lowering the primary lowering path.
- Expand type-driven checking for expected expression positions, including
  returns, call arguments, struct fields, `case` arms, `if` branches,
  `with`/`for reduce` bodies, closures, field access, statics, array literals,
  and option `some(...)` wrappers.
- Infer downstream types through value uses such as comparisons,
  `binary_search_by_key`, receiver method calls, mutable `Vec::push`, option
  case bindings, option adapters, package free functions, and `Self`-based impl
  callables.
- Import free functions from configured Cargo packages in addition to impl
  methods.
- Resolve `Self` types in impl callable metadata to the concrete impl target.
- Keep `__rustq_callables__/0` exports limited to local RustQ callables instead
  of embedding all external/package callables into every module. External
  callables are still available during compilation through cached source/package
  resolution.
- Document item-generating `defrustmacro` patterns for compact generated Rust
  that keeps implementation logic in Rusty-Elixir.
- Document when to use ordinary Elixir `defmacro` for authoring-layer reuse
  versus `defrustmacro` for intentionally reducing generated Rust size.

### Fixed

- Parse Rust bare function pointer types structurally through `syn` metadata
  instead of regexing rendered Rust type strings.
- Mark function pointer types as non-decodable where Rustler decoding cannot be
  derived safely.
- Auto-borrow binary-search keys, array literals expected as slices, call
  arguments, option `some(...)` inners, option adapter inners, external statics,
  and several downstream value-use patterns.
- Avoid applying `?` to `Option<T>` values in `Result`/`NifResult` contexts where
  Rust does not support that propagation boundary.
- Infer external static types and generated static types for auto-borrowing.
- Preserve explicit `R.raw(...)` as an escape hatch while using structured `syn`
  metadata where available.
- Fix zero-cost package metadata reuse after Skia dogfood: generated checks that
  previously ballooned to roughly 75–80 seconds now avoid duplicating thousands
  of external callables into every module.

## v0.8.3 - 2026-06-28

- Infer propagation for source-backed receiver method calls when the receiver type is known.
- Index Rust source callables by normalized receiver target names.
- Strengthen metadata guidance for avoiding `unwrap!` when Rust source metadata can be configured.

## v0.8.2 - 2026-06-26

- Add the RustQ agent skill to the Hex package and documentation.
- Add guidance for authoring RustQ generators with `defrust`, AST builders,
  metadata, inference, and explicit escape boundaries.
- Document expression-oriented Rusty-Elixir style and recursion/reducer patterns.

## v0.8.1 - 2026-06-25

- Add Rustler fixed struct term helpers for cached keys, default values, and raw `NIF_TERM` map construction.
- Use `Atom::from_str` for generated cached atom helpers.
- Add missing Rust integer marker types to `RustQ.Type`.

## v0.8.0 - 2026-06-25

- Add semantic control-flow lowering for expression-oriented Rusty-Elixir.
- Support macro-generated `case` clauses in `defrust` lowering.

## v0.7.0 - 2026-06-25

- Add `ok_or!(option_expr, error_expr)` as the Rusty-Elixir idiom for explicit
  `Option<T>` to `Result<T, E>` propagation boundaries.
- Extend type-driven propagation inference with nested Rust module function
  metadata, downstream receiver-method let inference, `as_slice()` adapters,
  source-backed `From<A> for B` compatibility for `impl Into<B>`, and
  associated-type metadata such as `impl IntoIterator<Item = T>`.
- Add source-backed callable metadata from Rust source files, Cargo packages,
  and callable modules.
- Dogfood native RustQ AST generation in Rustler atom dispatch, tagged enum,
  macro item, and native codegen helper paths.
- Add structured diagnostics for RustQ configuration, source loading, lowering,
  and native rendering failures.

## v0.6.0 - 2026-06-19

- Reframe Rusty Elixir as the high-level `defrust` authoring surface.
- Add external Rust type specs through ordinary remote types such as
  `GeneratedOpts.OvalOpts.t(RustQ.Type.lifetime(:a))`.
- Add ordinary Elixir macro expansion before `defrust` lowering so reusable
  Rusty-Elixir body fragments can use `defmacro`, `quote`, and `unquote`.
- Lower plural alias calls such as `Atoms.fill()` to snake-case Rust module calls
  such as `atoms::fill()`.
- Demote `RustQ.Meta.quoted` and `RustQ.Type.path` to low-level escape
  hatches instead of the normal authoring style.
- Add small AST reuse bridges for RustQ-owned codegen helpers:
  `RustQ.Rust.ast_item/1`, `RustQ.Rust.ast_items/1`, and the internal
  `RustQ.Meta.item(module, name)` / `items(module, names)` / `ast!(module, name)`
  helpers.
- Add Rust AST support for receiver arguments and lifetime-bearing impl blocks,
  including Rustler shapes such as `impl<'a> rustler::Decoder<'a> for Type` and
  `fn encode<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a>`.
- Dogfood Rustler helper generation through `defrust` and RustQ AST builders:
  term helpers, opts helpers, term builders, cached atoms, atom decoders, tagged
  enum decoders/encoders, resources, and term decoder shells no longer rely on
  hand-written helper templates. Explicit raw `NIF_TERM` builders remain the
  unsafe escape hatch.

## v0.5.1 - 2026-06-15

- Add generic Rust expression builders:
  - `Rust.call_expr/3`
  - `Rust.some/1`
  - `Rust.none/0`
  - `Rust.tuple/1`
  - `Rust.cast/2`
  - `Rust.question/1`
  - `Rust.ref_expr/2`

## v0.5.0 - 2026-06-15

- Add template includes.
- Add composable RustQ splice groups.
- Use plain keyword splices for composition.
- Add structured include diagnostics.
- Add rustfmt option.
- Add generic Rust body/control-flow builders:
  - `Rust.block/1`
  - `Rust.let_/2`
  - `Rust.let_mut/2`
  - `Rust.assign/2`
  - `Rust.call_stmt/3`
  - `Rust.return_if/2`
  - `Rust.if_/3`
  - `Rust.if_let/4`
  - `Rust.match_/2`
- Document macro token placeholder limitation.

## v0.4.0 - 2026-06-06

- Add generic Rustler builders for atom decoders, atom dispatch functions, and
  keyword/options helper functions.

## v0.3.0 - 2026-06-06

- Remove the generic Rustler schema field group DSL. Prefer explicit fields in
  RustQ schemas or project-specific macros for domain shorthand.

## v0.2.2 - 2026-06-03

- Add `RustQ.Rustler.resource_handle/2` for generating a Rustler resource plus
  a decoder for Elixir-facing resource handle structs/maps.
- Add Rustler schema field groups for reusable field sets with `use_fields/1`.
- Let Rustler schema nodes override generated Rust type names and Elixir module
  names with `rust:` and `module:`.

## v0.2.1 - 2026-06-03

- Add `RustQ.Rustler.nif_export/2` and `nif_exports/1` for generating exported
  Rustler NIF functions that delegate to handwritten implementation functions.

## v0.2.0 - 2026-06-02

- Replace the separate `__expr_`, `__type_`, and `__splice_` placeholder
  prefixes with one visually distinct `__rq_` placeholder prefix.
- Templates now use forms like `__rq_Name`, `__rq_value!()`,
  `__rq_fields: (),`, and `__rq_items!();`.

## v0.1.2 - 2026-06-02

- Let Rustler schema field types reference schema nodes and tagged enums by
  schema name, so examples can use `Content` instead of generated Rust names
  like `ExContent`.

## v0.1.1 - 2026-06-02

- Keep the packaged NIF crate out of parent Cargo workspaces when RustQ is used
  inside workspace-based projects.

## v0.1.0 - 2026-06-02

Initial release.

- Parse, validate, render, bind, and splice Rust templates from Elixir.
- `~R` sigil for inline Rust templates.
- Rust fragment builders for functions, structs, enums, impls, fields, constants, uses, modules, and type aliases.
- Rustler helper generators for atoms, NIFs, resources, option decoders, term helpers, term decoders, NIF structs, tagged enums, cached atoms, safe term builders, and explicit raw `NIF_TERM` builders.
- `rustq.exs` manifest DSL plus `mix rustq.gen` for generated file syncing and stale checks.
- Rustler schema DSL for generating Rust NIF structs and tagged enums from Elixir schema definitions.
