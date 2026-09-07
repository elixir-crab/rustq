# GPUI slider integration fixture

Run from any directory after installing RustQ's test dependencies:

```sh
bash integration/gpui_slider/run.sh
# Or clone from a local repository, without using its uncommitted files:
bash integration/gpui_slider/run.sh /path/to/gpui
```

The runner clones GPUI at `23422973f6a327fee192cb38243f27d3ed108d34` into a new temporary directory. It never patches the supplied repository. Cargo output uses that temporary directory too. The checkout and logs are retained for inspection; the runner prints their location.

Requirements: Elixir/Mix, Rust/Cargo, Git, network access for uncached dependencies, and GPUI's native platform build prerequisites. This is an opt-in, relatively expensive fixture, not part of RustQ's normal unit suite.

## What it validates

- `generate.exs` authors event handling in `defrust`, reading real `ControlledBinding` metadata.
- `slider.patch` connects generated behavior to the existing generic slider subscription. It intentionally leaves the surrounding GPUI lifecycle and typed callback signature in Rust.
- `behavior_tests.rs` checks emitted payloads, pending-value reconciliation, release tracking, failed delivery rollback, and unbound events.
- `subscription.exs` separately builds a fully structural subscription with `Context<()>`; Cargo metadata locates the pinned GPUI source, with no machine-specific checkout paths.
- The patched component crate passes its native tests and Clippy with warnings denied.

This fixture does not create a platform window, exercise OS event delivery, or demonstrate full generic trait inference. `EventEmitter<Evt>` solving and authoring the surrounding generic declaration remain separate work.
