defmodule RustQ.Syn.IndexTest do
  use ExUnit.Case, async: true

  alias RustQ.Cargo.Package
  alias RustQ.Syn.Enum, as: SynEnum
  alias RustQ.Syn.Index
  alias RustQ.Syn.Type
  alias RustQ.Syn.TypeAlias
  alias RustQ.Syn.Use, as: SynUse

  @moduletag :tmp_dir

  test "builds package-aware indexes from Cargo metadata" do
    index =
      Index.from_package("rustq_nif", manifest_path: "native/rustq_nif/Cargo.toml")

    assert %Package{name: "rustq_nif"} = index.package
    assert map_size(index.files) > 0
  end

  test "caches package indexes" do
    Index.clear_cached_package("rustq_nif",
      manifest_path: "native/rustq_nif/Cargo.toml"
    )

    first =
      Index.cached_package("rustq_nif", manifest_path: "native/rustq_nif/Cargo.toml")

    second =
      Index.cached_package("rustq_nif", manifest_path: "native/rustq_nif/Cargo.toml")

    assert first == second
    assert %Package{name: "rustq_nif"} = first.package
  after
    Index.clear_cached_package("rustq_nif",
      manifest_path: "native/rustq_nif/Cargo.toml"
    )
  end

  test "refreshes cached package indexes when package source changes", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "package")

    manifest_path = Path.join(dir, "Cargo.toml")
    lib_path = Path.join([dir, "src", "lib.rs"])

    File.mkdir_p!(Path.dirname(lib_path))

    on_exit(fn ->
      Index.clear_cached_package("rustq_cache_fixture", manifest_path: manifest_path)
    end)

    File.write!(manifest_path, """
    [package]
    name = "rustq_cache_fixture"
    version = "0.1.0"
    edition = "2021"
    """)

    File.write!(lib_path, "pub fn first() -> u32 { 1 }\n")

    first = Index.cached_package("rustq_cache_fixture", manifest_path: manifest_path)

    assert [%RustQ.Syn.Function{name: "first"}] =
             RustQ.Syn.functions(Map.fetch!(first.files, lib_path))

    File.write!(lib_path, "pub fn second() -> u32 { 2 }\n")

    second = Index.cached_package("rustq_cache_fixture", manifest_path: manifest_path)

    assert [%RustQ.Syn.Function{name: "second"}] =
             RustQ.Syn.functions(Map.fetch!(second.files, lib_path))
  end

  test "refreshes cached package indexes when a source file is added", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "package")

    manifest_path = Path.join(dir, "Cargo.toml")
    lib_path = Path.join([dir, "src", "lib.rs"])
    added_path = Path.join([dir, "src", "added.rs"])

    File.mkdir_p!(Path.dirname(lib_path))

    on_exit(fn ->
      Index.clear_cached_package("rustq_package_add_fixture", manifest_path: manifest_path)
    end)

    File.write!(manifest_path, """
    [package]
    name = "rustq_package_add_fixture"
    version = "0.1.0"
    edition = "2021"
    """)

    File.write!(lib_path, "pub fn first() {}\n")
    first = Index.cached_package("rustq_package_add_fixture", manifest_path: manifest_path)
    refute Map.has_key?(first.files, added_path)

    File.write!(added_path, "pub fn added() {}\n")
    second = Index.cached_package("rustq_package_add_fixture", manifest_path: manifest_path)

    assert [%RustQ.Syn.Function{name: "added"}] =
             RustQ.Syn.functions(Map.fetch!(second.files, added_path))
  end

  test "indexes enums by name", %{tmp_dir: tmp_dir} do
    path =
      write_source!(tmp_dir, """
      pub enum ClipOp { Intersect, Difference }
      """)

    index = Index.from_paths([path])

    assert [%SynEnum{name: "ClipOp"}] = Index.enums(index)

    assert {:ok,
            %SynEnum{
              variants: ["Intersect", "Difference"],
              variant_shapes: [
                %RustQ.Syn.Variant{name: "Intersect", kind: :unit},
                %RustQ.Syn.Variant{name: "Difference", kind: :unit}
              ]
            }} = Index.enum(index, "ClipOp")

    assert %SynEnum{name: "ClipOp"} = Index.enum!(index, "ClipOp")
  end

  test "indexes use aliases by alias", %{tmp_dir: tmp_dir} do
    path =
      write_source!(tmp_dir, """
      pub use sb::SkPaint_Cap as Cap;
      use crate::Paint;
      """)

    index = Index.from_paths([path])

    assert [
             %SynUse{
               path: "sb::SkPaint_Cap",
               segments: ["sb", "SkPaint_Cap"],
               alias: "Cap",
               visibility: :public,
               source_path: ^path
             },
             %SynUse{path: "crate::Paint", alias: "Paint", visibility: :private}
           ] = Index.uses(index)

    assert {:ok, %SynUse{path: "sb::SkPaint_Cap"}} =
             Index.use_alias(index, "Cap")

    assert %SynUse{alias: "Cap"} = Index.use_alias!(index, "Cap")
  end

  test "indexes glob reexports structurally", %{tmp_dir: tmp_dir} do
    path =
      write_source!(tmp_dir, """
      pub use blend_mode::*;
      """)

    index = Index.from_paths([path])

    assert [
             %SynUse{
               path: "blend_mode",
               segments: ["blend_mode"],
               alias: nil,
               glob?: true,
               visibility: :public
             }
           ] = Index.uses(index)
  end

  test "indexes type aliases by name", %{tmp_dir: tmp_dir} do
    path =
      write_source!(tmp_dir, """
      pub type PathOp = skia_bindings::SkPathOp;
      type Local = crate::Private;
      """)

    index = Index.from_paths([path])

    assert [
             %TypeAlias{
               name: "PathOp",
               visibility: :public,
               type: "skia_bindings :: SkPathOp",
               source_path: ^path
             },
             %TypeAlias{name: "Local", visibility: :private}
           ] = Index.type_aliases(index)

    assert {:ok, %TypeAlias{name: "PathOp"}} =
             Index.type_alias(index, "PathOp")

    assert %TypeAlias{name: "PathOp"} = Index.type_alias!(index, "PathOp")
  end

  test "finds public type names for aliased Rust types", %{tmp_dir: tmp_dir} do
    path =
      write_source!(tmp_dir, """
      pub type PathOp = skia_bindings::SkPathOp;
      type PrivateOp = skia_bindings::SkPrivateOp;
      """)

    index = Index.from_paths([path])

    assert {:ok, "PathOp"} = Index.public_type_name(index, "SkPathOp")
    assert "PathOp" = Index.public_type_name!(index, "SkPathOp")
    assert :error = Index.public_type_name(index, "SkPrivateOp")
  end

  test "prefers public root reexports for aliased Rust types", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "sources")
    File.mkdir_p!(dir)
    paint_path = Path.join(dir, "paint.rs")
    core_path = Path.join(dir, "core.rs")

    File.write!(paint_path, "pub use sb::SkPaint_Cap as Cap;\n")
    File.write!(core_path, "pub use paint::Cap as PaintCap;\n")

    index = Index.from_paths([paint_path, core_path])

    assert {:ok, "PaintCap"} = Index.public_type_name(index, "SkPaint_Cap")
  end

  test "follows public reexport chains for aliased Rust types", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "sources")
    File.mkdir_p!(dir)
    paint_path = Path.join(dir, "paint.rs")
    core_path = Path.join(dir, "core.rs")
    lib_path = Path.join(dir, "lib.rs")

    File.write!(paint_path, "pub use sb::SkPaint_Cap as Cap;\n")
    File.write!(core_path, "pub use paint::Cap as PaintCap;\n")
    File.write!(lib_path, "pub use core::PaintCap as PublicPaintCap;\n")

    index = Index.from_paths([paint_path, core_path, lib_path])

    assert {:ok, "PublicPaintCap"} = Index.public_type_name(index, "SkPaint_Cap")
  end

  test "indexes impl methods by target", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "impl.rs")

    File.write!(path, """
    impl Canvas {
      pub fn draw_rect(&self, rect: impl AsRef<Rect>, paint: &Paint) -> &Self { self }
    }

    impl Path {
      pub fn op(&self, other: &Path, op: PathOp) -> Option<Path> { None }
    }
    """)

    index = Index.from_paths([path])

    assert %RustQ.Syn.Method{name: "draw_rect", source_path: ^path, source_line: 2} =
             Index.method!(index, "Canvas", "draw_rect")

    assert {:ok, %RustQ.Syn.Method{name: "op"}} = Index.method(index, "Path", "op")
    assert :error = Index.method(index, "Canvas", "missing")
  end

  test "type helper predicates match common Rust type shapes" do
    [method] =
      """
      impl Canvas {
        pub fn draw_rect(&self, rect: impl AsRef<Rect>, paint: &Paint) -> &Self { self }
      }
      """
      |> RustQ.Syn.parse!()
      |> RustQ.Syn.methods()

    [self_arg, rect_arg, paint_arg] = method.args

    assert %Type.Ref{} = self_arg.type_ast
    assert Type.impl_trait?(rect_arg.type_ast, "AsRef", ["Rect"])
    assert Type.ref_to?(paint_arg.type_ast, "Paint")
  end

  defp write_source!(tmp_dir, source) do
    path = Path.join(tmp_dir, "source.rs")
    File.write!(path, source)
    path
  end
end
