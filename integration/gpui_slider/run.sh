#!/usr/bin/env bash
set -euo pipefail

fixture=$(cd "$(dirname "$0")" && pwd)
rustq=$(cd "$fixture/../.." && pwd)
source_repo=${1:-https://github.com/elixir-crab/gpui.git}
revision=23422973f6a327fee192cb38243f27d3ed108d34
workspace=$(mktemp -d "${TMPDIR:-/tmp}/rustq-gpui-slider.XXXXXX")
echo "Fixture workspace: $workspace"
# Keep the isolated checkout and logs for inspection, including on failure.
git clone --no-hardlinks --no-checkout "$source_repo" "$workspace/gpui"
git -C "$workspace/gpui" checkout --detach "$revision"
export RUSTQ_GPUI_ROOT="$workspace/gpui"
export CARGO_TARGET_DIR="$workspace/target"
export MIX_ENV=test

git -C "$RUSTQ_GPUI_ROOT" apply --check "$fixture/slider.patch"
git -C "$RUSTQ_GPUI_ROOT" apply "$fixture/slider.patch"
cp "$fixture/behavior_tests.rs" "$RUSTQ_GPUI_ROOT/apps/gpui_components/native/src/slider_behavior_tests.rs"
cd "$rustq"
mix run "$fixture/generate.exs" > "$workspace/generation.log" 2>&1
mix run "$fixture/subscription.exs" > "$workspace/metadata.log" 2>&1
# Resolve rust-toolchain.toml and .cargo configuration from the consumer.
cd "$RUSTQ_GPUI_ROOT"
cargo test --locked --manifest-path "$RUSTQ_GPUI_ROOT/Cargo.toml" -p gpui_components --features native-render 2>&1 | tee "$workspace/tests.log"
cargo clippy --locked --manifest-path "$RUSTQ_GPUI_ROOT/Cargo.toml" -p gpui_components --features native-render --all-targets -- -D warnings 2>&1 | tee "$workspace/clippy.log"
echo "Slider fixture passed: $workspace"
