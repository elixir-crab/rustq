defmodule RustQ.Native.ManifestTest do
  use ExUnit.Case, async: true

  alias RustQ.Native.Manifest

  test "encodes Cargo policy as TOML data" do
    source = Manifest.encode!("example", [{"crc32fast", "1"}])
    manifest = TomlElixir.decode!(source, spec: :"1.0.0")

    assert manifest["package"] == %{
             "name" => "example",
             "version" => "0.1.0",
             "edition" => "2021",
             "publish" => false
           }

    assert manifest["lib"] == %{"name" => "example", "crate-type" => ["cdylib"]}
    assert manifest["dependencies"] == %{"rustler" => "0.37", "crc32fast" => "1"}
    assert Manifest.encode!("example", [{"crc32fast", "1"}]) == source
  end

  test "round trips dependency strings without hand-written escaping" do
    path = Path.join(System.tmp_dir!(), "native \"quoted\" \\ unicode-λ")
    git = "https://example.test/repo?value=\"quoted\""

    options = [
      path: path,
      git: git,
      branch: "feature/λ",
      features: ["quoted\"", "back\\slash"],
      default_features: false
    ]

    manifest =
      Manifest.encode!("example", [{"native-lib", options}]) |> TomlElixir.decode!(spec: :"1.0.0")

    assert manifest["dependencies"]["native-lib"] == %{
             "path" => Path.expand(path),
             "git" => git,
             "branch" => "feature/λ",
             "features" => ["quoted\"", "back\\slash"],
             "default-features" => false
           }
  end

  test "rejects malformed and duplicate dependencies before serialization" do
    for dependencies <- [
          [{"bad.name", "1"}],
          [{"rustler", "1"}],
          [{"a", "1"}, {"a", "2"}],
          [{"a", [features: [:invalid]]}],
          [{"a", [version: "1", version: "2"]}],
          [{"a", [unexpected: true]}]
        ] do
      assert_raise ArgumentError, fn -> Manifest.encode!("example", dependencies) end
    end
  end
end
