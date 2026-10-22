defmodule RustQ.Corpus.Propagation.ImplIntoOption do
  @moduledoc "Propagate fallible values passed to impl Into<Option<T>> arguments."

  use RustQ.Meta, rust_sources: ["test/fixtures/into_option_method.rs"]

  alias RustQ.Type, as: R

  @spec decode_filter(term()) :: R.nif_result(R.path(:ImageFilter))
  defrust decode_filter(_term) do
    {:ok, ImageFilter.default()}
  end

  @spec run(R.mut_ref(R.path(:Paint)), term()) :: R.nif_result(R.unit())
  defrust run(paint, term) do
    paint.set_image_filter(decode_filter(term))
    :ok
  end

  @spec optional_matrix(term()) :: R.nif_result(R.option(R.path(:Matrix)))
  defrust optional_matrix(_term) do
    {:ok, nil}
  end

  @spec run_ref_option(R.ref(R.path(:RuntimeEffect)), term()) :: R.nif_result(R.path(:Shader))
  defrust run_ref_option(effect, term) do
    ok_or!(effect.make_shader(optional_matrix(term)), badarg())
  end
end
