# RustQ native-authoring review map

These changes are exploratory and uncommitted. Suggested review groups:

1. **Closure representation** — move capture; pattern/typed AST arguments; expected callback parameter environments; shadowing. Entry points: `AST.Closure`, `Builder.closure`, `Meta.Lower`, move/generic callback tests.
2. **Callable return types** — `R.impl` using ordinary function signatures, explicit kind/traits/lifetime. Structured callable fields extend the existing `TypeImplTrait` while preserving legacy string bounds. Tests: move closure and option validation.
3. **Foreign metadata and substitution** — parenthesized trait arguments/output; declared impl/method type parameter names; structural receiver target; substitution of known receiver/argument types. Tests: Syn callable traits and binding substitution.
4. **Rendering/borrowing corrections** — known clone/deref inference, reference/unary receiver precedence, field shorthand, unit-return cleanup, ignored-error result matches. Tests: typing, decoder, corpus, generic callback compilation.
5. **Real consumer fixture** — `integration/gpui_slider/run.sh`; pinned fresh clone; generated behavior connected to real subscription; five behavior tests; native test/Clippy validation.

## Established validation

- Normal RustQ `mix ci` passes.
- Fresh source checkout with fresh dependencies and normal `_build` passes its test suite (774 tests at time of clean-build check).
- Fresh-clone slider fixture passes component tests and Clippy.

## Remaining limitations / review risks

- Unknown pattern receiver types no longer infer mutability from method names. The slider uses an explicit local mutable borrow for unresolved MutexGuard receivers. General smart-pointer/Deref inference remains unimplemented.
- Generic substitutions are limited; free-function declarations, return specialization, associated types and `EventEmitter<Evt>` solving are not complete.
- Replaced generic leaf metadata is rebuilt from structural AST. Rich external metadata on actual types is not retained by an AST-only binding map.
- Conflicts now diagnose; other unification mismatches can remain unresolved. More call-site diagnostics are needed before broad inference claims.
- The public marker has no BEAM callback codec. `R.impl` is native-only and its supported placement needs further validation.
- The GPUI fixture leaves the surrounding generic lifecycle function and callback type annotation handwritten. Tests call event handling directly; there is no platform-window dispatch test.
- Elixir fallback rendering and native rendering should be reviewed together; some lint cleanup currently occurs only in the native parser.
- This map is not a completed code review or a release-readiness claim. Do not merge/publish solely on the positive fixture result.
