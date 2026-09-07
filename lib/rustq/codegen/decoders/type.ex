defmodule RustQ.Codegen.Decoders.Type do
  @moduledoc false

  use RustQ.Codegen.DefrustModule,
    callable_modules: [RustQ.Codegen.DecoderHelpers, RustQ.Codegen.Helpers]

  @spec path_parts(term()) :: R.nif_result(String.t())
  defrust path_parts(term) do
    parts = unwrap!(Super.decode_string_list(term))
    ok(parts.join("::"))
  end

  @spec decode_lifetime_list(term()) :: R.nif_result(R.vec(String.t()))
  defrust decode_lifetime_list(term) do
    Super.decode_string_list(term)
  end

  @spec decode_type_path(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_path(term) do
    parts = required_string_list(term, "parts")
    lifetimes = decode_lifetime_list(required_field(term, "lifetimes"))
    generics = required_type_list(term, "generics")
    Super.parse_type_path_with_generics(parts, lifetimes, generics)
  end

  @spec decode_type_unit(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_unit(term) do
    Super.parse_type_unit(term)
  end

  @spec decode_type_raw(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_raw(term) do
    source = required_field(term, "source").decode()
    Super.parse_type_raw(source)
  end

  @spec decode_type_ref(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_ref(term) do
    inner = required_type(term, "inner")
    mutable = required_field(term, "mutable").decode()
    lifetime = optional_atom_key(term, "lifetime")
    Super.parse_type_ref(inner, mutable, lifetime)
  end

  @spec decode_type_option(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_option(term) do
    Super.parse_type_generic("Option", [required_type(term, "inner")])
  end

  @spec decode_type_result(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_result(term) do
    Super.parse_type_generic("Result", [required_type(term, "ok"), required_type(term, "error")])
  end

  @spec decode_type_nif_result(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_nif_result(term) do
    Super.parse_type_generic("NifResult", [required_type(term, "inner")])
  end

  @spec decode_type_vec(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_vec(term) do
    Super.parse_type_generic("Vec", [required_type(term, "inner")])
  end

  @spec decode_type_slice(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_slice(term) do
    Super.parse_type_slice(required_type(term, "inner"))
  end

  @spec decode_type_array(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_array(term) do
    Super.parse_type_array(required_type(term, "inner"), required_field(term, "size"))
  end

  @spec decode_type_bare_fn(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_bare_fn(term) do
    abi_term = required_field(term, "abi")

    abi =
      if is_nil(abi_term) do
        nil
      else
        some(decode_as!(abi_term, String.t()))
      end

    Super.parse_type_bare_fn(
      required_type_list(term, "args"),
      Super.decode_optional_type_field(term, "returns"),
      decode_lifetime_list(required_field(term, "lifetimes")),
      required_field(term, "unsafe").decode(),
      required_field(term, "external").decode(),
      abi,
      required_field(term, "variadic").decode()
    )
  end

  @spec decode_type_impl_trait(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_impl_trait(term) do
    lifetime_term = required_field(term, "lifetime")
    lifetime = if is_nil(lifetime_term), do: nil, else: some(Super.atom_or_string(lifetime_term))

    Super.parse_callable_impl(
      Super.decode_optional_type_field(term, "callable"),
      Super.atom_or_string(required_field(term, "kind")),
      required_type_list(term, "traits"),
      lifetime,
      required_string_list(term, "bounds")
    )
  end

  @spec decode_type_tuple(term()) :: R.nif_result(R.path(:Type))
  defrust decode_type_tuple(term) do
    Super.parse_type_tuple(required_type_list(term, "items"))
  end
end
