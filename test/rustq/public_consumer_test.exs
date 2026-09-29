defmodule RustQ.PublicConsumerTest do
  use RustQ.Test.PackageCase, async: false

  @moduletag :package_test
  @moduletag timeout: 600_000

  @root Path.expand("../..", __DIR__)
  @fixture Path.join(@root, "integration/public_consumer")
  @zero_rust_fixture Path.join(@root, "integration/zero_rust_consumer")

  setup_all do
    build_package_workspace!(@root)
  end

  test "the Hex artifact ships its public compatibility contract", %{package: package} do
    assert File.regular?(Path.join(package, "SKILL.md"))
    assert File.regular?(Path.join(package, "guides/compatibility.md"))
    assert File.regular?(Path.join(package, "guides/generating-rust.md"))
    assert File.regular?(Path.join(package, "guides/zero-rust-nifs.md"))
    assert File.regular?(Path.join(package, "lib/rustq/test.ex"))
  end

  test "the packaged generator APIs support a clean external consumer", context do
    consumer = copy_fixture!(@fixture, context.workspace, "public-consumer")
    env = package_env(context.package)

    run!(consumer, "mix", ["deps.get"], env)
    run!(consumer, "mix", ["rustq.gen", "--check"], env)
    run!(consumer, "mix", ["test"], env)
    run!(consumer, "cargo", ["check", "--manifest-path", "native/Cargo.toml"], env)

    run!(
      consumer,
      "cargo",
      ["clippy", "--manifest-path", "native/Cargo.toml", "--", "-D", "warnings"],
      env
    )

    generated = File.read!(Path.join(consumer, "native/src/generated.rs"))
    assert generated =~ "fn increment_all"
    assert generated =~ "struct Input"

    encoders = File.read!(Path.join(consumer, "native/src/generated_ir_encoders.rs"))
    assert encoders =~ "fn encode_op<'a>(env: rustler::Env<'a>, value: &Op<'_>)"
    assert encoders =~ ~S|r#type = "type"|
  end

  test "the packaged zero-Rust APIs build a formatted, lint-clean native crate", context do
    assert Path.wildcard(Path.join(@zero_rust_fixture, "**/*.rs")) == []
    refute File.exists?(Path.join(@zero_rust_fixture, "Cargo.toml"))
    refute File.exists?(Path.join(@zero_rust_fixture, "rustq.exs"))

    consumer = copy_fixture!(@zero_rust_fixture, context.workspace, "zero-rust-consumer")

    env = [
      {"RUSTFLAGS", ~s|--check-cfg=cfg(feature,values("extended"))|}
      | package_env(context.package)
    ]

    run!(consumer, "mix", ["deps.get"], env)
    run!(consumer, "mix", ["test"], env)

    [native_source] =
      Path.wildcard(Path.join(consumer, "_build/test/rustq_native/*/src/lib.rs"))

    native_manifest = native_source |> Path.dirname() |> Path.dirname() |> Path.join("Cargo.toml")
    run!(consumer, "cargo", ["fmt", "--check", "--manifest-path", native_manifest], env)

    run!(
      consumer,
      "cargo",
      ["clippy", "--manifest-path", native_manifest, "--", "-D", "warnings"],
      env
    )

    source = File.read!(native_source)
    assert source =~ "#[rustler::nif]"
    assert source =~ "fn add(left: i64, right: i64) -> i64"
    assert source =~ ~s|rustler::init! { "Elixir.RustQZeroRustConsumer.Native" }|

    release_env = [{"RUSTQ_TEST_RELEASE", "1"} | env]
    run!(consumer, "mix", ["clean"], release_env)
    run!(consumer, "mix", ["test"], release_env)

    rebuild_feature!(consumer, native_manifest, release_env)
    run!(consumer, "mix", ["test", "--no-compile"], [{"RUSTQ_TEST_FEATURE", "1"} | release_env])
  end
end
