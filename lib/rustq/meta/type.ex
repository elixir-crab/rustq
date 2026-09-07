defmodule RustQ.Meta.Type do
  @moduledoc """
  Structural metadata for an Elixir typespec lowered by RustQ.

  `RustQ.Spec.type/2` and `RustQ.Spec.aliases/1` return this struct. The
  `:kind` field is the primary semantic classification (`:f64`, `:bool`,
  `:tuple`, `:struct`, `:enum`, `:type`, and so on). The `:ast` field carries
  the RustQ Rust type AST used for rendering, `:rust` is its rendered Rust type,
  and `:meta` carries shape-specific metadata such as:

    * `:elements` for tuple element types
    * `:fields` for map/struct field types
    * `:elixir_name` for local aliases and enum aliases
    * `:elixir_module`, `:elixir_type`, and `:elixir_args` for external
      Elixir remote types such as `Skia.Path.t()`

  Prefer consuming this structure directly at codegen boundaries instead of
  parsing rendered Rust type strings.
  """

  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.Identifier
  alias RustQ.Syn.Type, as: SynType

  defguardp is_ast_tuple(tuple)
            when tuple_size(tuple) == 3 and is_atom(elem(tuple, 0)) and is_list(elem(tuple, 1)) and
                   is_list(elem(tuple, 2))

  defstruct [:kind, :rust, :ast, meta: %{}]

  @type category ::
          :number
          | :integer
          | :boolean
          | :atom
          | :string
          | :term
          | :enum
          | {:tuple, [t()]}
          | {:alias, atom()}
          | :type

  @type t :: %__MODULE__{kind: atom(), rust: String.t(), ast: term(), meta: map()}

  @integer_kinds [:i8, :i16, :i32, :i64, :isize, :u8, :u16, :u32, :u64, :usize]
  @number_kinds [:f32, :f64]

  @doc "Returns the semantic category for a lowered RustQ type."
  @spec category(t()) :: category()
  def category(%__MODULE__{kind: kind}) when kind in @number_kinds, do: :number
  def category(%__MODULE__{kind: kind}) when kind in @integer_kinds, do: :integer
  def category(%__MODULE__{kind: :bool}), do: :boolean
  def category(%__MODULE__{kind: :atom}), do: :atom
  def category(%__MODULE__{kind: :term}), do: :term
  def category(%__MODULE__{kind: kind}) when kind in [:enum, :rust_enum], do: :enum
  def category(%__MODULE__{kind: :tuple, meta: %{elements: elements}}), do: {:tuple, elements}
  def category(%__MODULE__{kind: :alias, meta: %{elixir_name: name}}), do: {:alias, name}
  def category(%__MODULE__{meta: %{elixir_module: String, elixir_type: :t}}), do: :string
  def category(%__MODULE__{}), do: :type

  @doc "Returns true when a type originated from a specific Elixir remote type."
  @spec external?(t(), module(), atom()) :: boolean()
  def external?(%__MODULE__{meta: %{elixir_module: module, elixir_type: type}}, module, type),
    do: true

  def external?(%__MODULE__{}, _module, _type), do: false

  @doc "Returns true when the type AST structurally contains the given lifetime."
  @spec lifetime?(t(), atom()) :: boolean()
  def lifetime?(%__MODULE__{ast: ast, meta: meta}, lifetime \\ :a) when is_atom(lifetime) do
    ast_lifetime?(ast, lifetime) or meta_lifetime?(meta, lifetime)
  end

  @doc "Returns true for wrapper types that can propagate with Rust `?`."
  @spec propagates?(t()) :: boolean()
  def propagates?(%__MODULE__{kind: kind}) when kind in [:result, :nif_result, :option], do: true
  def propagates?(%__MODULE__{}), do: false

  @doc "Returns the success/inner type of `Result`, `NifResult`, or `Option` wrappers."
  @spec inner(t()) :: t() | nil
  def inner(%__MODULE__{kind: :option, meta: %{inner: %__MODULE__{} = inner}}), do: inner
  def inner(%__MODULE__{kind: :result, meta: %{ok: %__MODULE__{} = ok}}), do: ok
  def inner(%__MODULE__{kind: :nif_result, meta: %{inner: %__MODULE__{} = inner}}), do: inner
  def inner(%__MODULE__{kind: :resource, meta: %{inner: %__MODULE__{} = inner}}), do: inner
  def inner(%__MODULE__{kind: :option, ast: %AST.TypeOption{inner: inner}}), do: ast_type(inner)
  def inner(%__MODULE__{kind: :result, ast: %AST.TypeResult{ok: ok}}), do: ast_type(ok)

  def inner(%__MODULE__{
        kind: :resource,
        ast: %AST.TypePath{parts: [:ResourceArc], generics: [inner]}
      }),
      do: ast_type(inner)

  def inner(%__MODULE__{kind: :nif_result, ast: %AST.TypeNifResult{inner: inner}}),
    do: ast_type(inner)

  def inner(%__MODULE__{}), do: nil

  @doc "Returns the error type of a `Result` wrapper."
  @spec error(t()) :: t() | nil
  def error(%__MODULE__{kind: :result, meta: %{error: %__MODULE__{} = error}}), do: error
  def error(%__MODULE__{kind: :result, ast: %AST.TypeResult{error: error}}), do: ast_type(error)
  def error(%__MODULE__{}), do: nil

  @doc "Returns the referenced inner type for `&T` or `&mut T` metadata."
  @spec ref_inner(t()) :: t() | nil
  def ref_inner(%__MODULE__{kind: kind, meta: %{inner: %__MODULE__{} = inner}})
      when kind in [:ref, :mut_ref],
      do: inner

  def ref_inner(%__MODULE__{ast: %AST.TypeRef{inner: inner}}), do: ast_type(inner)
  def ref_inner(%__MODULE__{}), do: nil

  @doc "Constructs reference type metadata for an inner type."
  @spec ref(t()) :: t()
  def ref(%__MODULE__{} = inner) do
    %__MODULE__{
      kind: :ref,
      rust: "&#{inner.rust}",
      ast: %AST.TypeRef{inner: inner.ast},
      meta: %{inner: inner}
    }
  end

  @doc "Constructs option type metadata for an inner type."
  @spec option(t()) :: t()
  def option(%__MODULE__{} = inner) do
    %__MODULE__{
      kind: :option,
      rust: "Option<#{inner.rust}>",
      ast: %AST.TypeOption{inner: inner.ast},
      meta: %{inner: inner}
    }
  end

  @doc "Returns a named structural field type, when available."
  @spec field_type(t(), atom()) :: t() | nil
  def field_type(%__MODULE__{meta: %{fields: fields}}, field)
      when is_atom(field) and is_list(fields) do
    Enum.find_value(fields, fn
      {^field, %__MODULE__{} = type, _presence} -> type
      {^field, %__MODULE__{} = type} -> type
      _other -> nil
    end)
  end

  def field_type(%__MODULE__{}, _field), do: nil

  @doc "Returns a callable lookup target normalized from structural type metadata."
  @spec callable_target(t()) :: String.t() | nil
  def callable_target(%__MODULE__{kind: kind, meta: %{inner: %__MODULE__{} = inner}})
      when kind in [:ref, :mut_ref],
      do: callable_target(inner)

  def callable_target(%__MODULE__{meta: %{syn_name: name}}) when is_binary(name), do: name

  def callable_target(%__MODULE__{ast: %AST.TypeRef{inner: inner}}),
    do: callable_target(ast_type(inner))

  def callable_target(%__MODULE__{ast: %AST.TypePath{parts: [_ | _] = parts}}),
    do: parts |> List.last() |> to_string()

  def callable_target(%__MODULE__{ast: %AST.TypeRaw{source: source}}) when is_binary(source) do
    source
    |> String.trim_leading()
    |> String.trim_leading("&")
    |> String.trim_leading()
    |> String.trim_leading("mut ")
    |> String.split("<", parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" -> nil
      target -> target
    end
  end

  def callable_target(%__MODULE__{}), do: nil

  @doc "Returns the element type for `Vec<T>` metadata."
  @spec vec_inner(t()) :: t() | nil
  def vec_inner(%__MODULE__{kind: :vec, meta: %{inner: %__MODULE__{} = inner}}), do: inner
  def vec_inner(%__MODULE__{ast: %AST.TypeVec{inner: inner}}), do: ast_type(inner)

  def vec_inner(%__MODULE__{ast: %AST.TypePath{parts: [:Vec], generics: [inner]}}),
    do: ast_type(inner)

  def vec_inner(%__MODULE__{}), do: nil

  @doc "Returns the element type for `[T]` / `&[T]` metadata."
  @spec slice_inner(t()) :: t() | nil
  def slice_inner(%__MODULE__{kind: :slice, meta: %{inner: %__MODULE__{} = inner}}), do: inner
  def slice_inner(%__MODULE__{ast: %AST.TypeSlice{inner: inner}}), do: ast_type(inner)

  def slice_inner(%__MODULE__{ast: %AST.TypeRef{inner: %AST.TypeSlice{inner: inner}}}),
    do: ast_type(inner)

  def slice_inner(%__MODULE__{}), do: nil

  @doc false
  @spec tuple([t()]) :: t()
  def tuple(elements) when is_list(elements) and elements != [] do
    type(:tuple, %AST.TypeTuple{items: Enum.map(elements, & &1.ast)}, %{elements: elements})
  end

  @doc "Constructs `Vec<T>` type metadata."
  @spec vec(t()) :: t()
  def vec(%__MODULE__{} = inner) do
    type(:vec, %AST.TypeVec{inner: inner.ast}, %{inner: inner})
  end

  @doc "Constructs borrowed slice metadata for a list-pattern tail."
  @spec slice_ref(t()) :: t()
  def slice_ref(%__MODULE__{} = inner) do
    type(
      :slice,
      %AST.TypeRef{inner: %AST.TypeSlice{inner: inner.ast}},
      %{inner: inner, borrowed: true}
    )
  end

  @doc """
  Returns the natural Rusty-Elixir input type for a callable expected type.

  This normalizes Rust adapter types into the value shape an author should pass
  before call-site coercions are emitted. For example, `&T` expects an authored
  `T`, `&[T]` expects an authored `Vec<T>`, and `impl IntoIterator<Item = T>`
  expects an authored `Vec<T>`.
  """
  @spec expected_input(t()) :: t()
  def expected_input(%__MODULE__{kind: :impl_trait, meta: %{traits: traits}} = type) do
    traits
    |> Enum.find_value(fn
      %__MODULE__{meta: %{syn_name: "Into", args: [%__MODULE__{} = inner]}} ->
        expected_input(inner)

      %__MODULE__{meta: %{syn_name: "IntoIterator", assoc: %{"Item" => %__MODULE__{} = item}}} ->
        vec(item)

      %__MODULE__{meta: %{syn_name: "AsRef", args: [%__MODULE__{} = inner]}} ->
        expected_input(inner)

      _trait ->
        nil
    end) || type
  end

  def expected_input(%__MODULE__{kind: :option} = type) do
    case inner(type) do
      %__MODULE__{} = inner ->
        expected_inner = expected_input(inner)
        type(:option, %AST.TypeOption{inner: expected_inner.ast}, %{inner: expected_inner})

      nil ->
        type
    end
  end

  def expected_input(%__MODULE__{} = type) do
    cond do
      slice_inner(type) -> vec(slice_inner(type))
      ref_inner(type) -> expected_input(ref_inner(type))
      true -> type
    end
  end

  @doc """
  Returns the concrete value type expected by a callable argument.

  This peels structural argument adapters such as `impl Into<T>` and the common
  `impl Into<Option<(A, B)>>` tuple case so propagation inference can compare a
  decoder's success type with the value the Rust call actually expects.
  """
  @spec expected_value(t()) :: t()
  def expected_value(%__MODULE__{kind: :impl_trait, meta: %{traits: traits}} = type) do
    traits
    |> Enum.find_value(fn
      %__MODULE__{meta: %{syn_name: "Into", args: [%__MODULE__{} = inner]}} ->
        expected_value(inner)

      %__MODULE__{meta: %{syn_name: "AsRef", args: [%__MODULE__{} = inner]}} ->
        expected_value(inner)

      _trait ->
        nil
    end) || type
  end

  def expected_value(%__MODULE__{kind: :alias, meta: %{target: %__MODULE__{} = target}}),
    do: expected_value(target)

  def expected_value(%__MODULE__{
        kind: :option,
        meta: %{inner: %__MODULE__{kind: :tuple} = inner}
      }),
      do: inner

  def expected_value(%__MODULE__{} = type), do: type

  @doc "Returns true when a value type can satisfy a callable expected argument type."
  @spec compatible_with_expected?(t() | nil, t() | nil) :: boolean()
  def compatible_with_expected?(%__MODULE__{} = value, %__MODULE__{} = expected) do
    expected_value = expected_value(expected)

    compatible?(value, expected_value) or
      as_ref_compatible?(value, expected) or
      (expected_value.kind == :option and compatible?(value, inner(expected_value)))
  end

  def compatible_with_expected?(_value, _expected), do: false

  defp as_ref_compatible?(%__MODULE__{} = value, %__MODULE__{
         kind: :impl_trait,
         meta: %{traits: traits}
       }) do
    Enum.any?(traits, fn
      %__MODULE__{meta: %{syn_name: "AsRef", args: [%__MODULE__{} = inner]}} ->
        compatible?(value, inner) or string_as_ref?(value, inner)

      _trait ->
        false
    end)
  end

  defp as_ref_compatible?(_value, _expected), do: false

  defp string_as_ref?(%__MODULE__{} = value, %__MODULE__{} = inner) do
    value.rust == "String" and inner.rust == "str"
  end

  @doc "Returns true when two lowered types are semantically compatible."
  @spec compatible?(t() | nil, t() | nil) :: boolean()
  def compatible?(%__MODULE__{kind: kind} = left, %__MODULE__{kind: kind} = right)
      when kind in [:option, :ref, :mut_ref] do
    exact_type?(left, right) or equivalent_type_name?(left, right) or
      compatible?(inner(left), inner(right))
  end

  def compatible?(%__MODULE__{} = left, %__MODULE__{} = right) do
    exact_type?(left, right) or equivalent_type_name?(left, right)
  end

  def compatible?(_left, _right), do: false

  defp exact_type?(%__MODULE__{ast: left}, %__MODULE__{ast: right}), do: left == right

  defp equivalent_type_name?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left
    |> equivalent_type_names()
    |> MapSet.disjoint?(equivalent_type_names(right))
    |> Kernel.not()
  end

  defp equivalent_type_names(%__MODULE__{} = type) do
    [
      type.rust,
      path_type_name(type.ast),
      type.meta[:syn_name] | List.wrap(type.meta[:equivalent_rust_names])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp path_type_name(%AST.TypePath{parts: [_ | _] = parts}),
    do: parts |> List.last() |> to_string()

  defp path_type_name(_ast), do: nil

  defp ast_lifetime?(%AST.TypePath{lifetimes: lifetimes, generics: generics}, lifetime) do
    lifetime in lifetimes or Enum.any?(generics, &ast_lifetime?(&1, lifetime))
  end

  defp ast_lifetime?(%AST.TypeRef{lifetime: lifetime}, lifetime), do: true
  defp ast_lifetime?(%AST.TypeRef{inner: inner}, lifetime), do: ast_lifetime?(inner, lifetime)
  defp ast_lifetime?(%AST.TypeOption{inner: inner}, lifetime), do: ast_lifetime?(inner, lifetime)
  defp ast_lifetime?(%AST.TypeVec{inner: inner}, lifetime), do: ast_lifetime?(inner, lifetime)
  defp ast_lifetime?(%AST.TypeSlice{inner: inner}, lifetime), do: ast_lifetime?(inner, lifetime)
  defp ast_lifetime?(%AST.TypeArray{inner: inner}, lifetime), do: ast_lifetime?(inner, lifetime)

  defp ast_lifetime?(%AST.TypeNifResult{inner: inner}, lifetime),
    do: ast_lifetime?(inner, lifetime)

  defp ast_lifetime?(%AST.TypeResult{ok: ok, error: error}, lifetime) do
    ast_lifetime?(ok, lifetime) or ast_lifetime?(error, lifetime)
  end

  defp ast_lifetime?(_ast, _lifetime), do: false

  defp meta_lifetime?(%{inner: %__MODULE__{} = inner}, lifetime), do: lifetime?(inner, lifetime)

  defp meta_lifetime?(%{elements: elements}, lifetime) when is_list(elements),
    do: Enum.any?(elements, &lifetime?(&1, lifetime))

  defp meta_lifetime?(%{fields: fields}, lifetime) when is_list(fields) do
    Enum.any?(fields, fn
      {_name, %__MODULE__{} = type, _presence} -> lifetime?(type, lifetime)
      _field -> false
    end)
  end

  defp meta_lifetime?(%{args: args}, lifetime) when is_list(args),
    do: Enum.any?(args, &lifetime?(&1, lifetime))

  defp meta_lifetime?(_meta, _lifetime), do: false

  @doc """
  Converts structured `RustQ.Syn.Type` metadata into a RustQ meta type.

  This is the first bridge from upstream Rust signatures into Rusty-Elixir type
  metadata. It preserves structured wrappers such as refs, options, results,
  slices, and paths, while falling back to `TypeRaw` for Syn shapes that do not
  yet expose enough structure to rebuild a richer RustQ AST node.
  """
  @spec from_syn(RustQ.Syn.type()) :: t()
  def from_syn(%SynType.Path{} = path), do: from_syn_path(path)

  def from_syn(%SynType.Ref{inner: inner, mutable: mutable, lifetime: lifetime}) do
    inner = from_syn(inner)

    type(
      ref_kind(mutable),
      %AST.TypeRef{inner: inner.ast, mutable: mutable, lifetime: syn_lifetime(lifetime)},
      %{inner: inner, lifetime: lifetime}
    )
  end

  def from_syn(%SynType.Option{inner: inner}) do
    inner = from_syn(inner)
    type(:option, %AST.TypeOption{inner: inner.ast}, %{inner: inner})
  end

  def from_syn(%SynType.Result{ok: ok, error: error}) do
    ok = from_syn(ok)
    error = from_syn(error)
    type(:result, %AST.TypeResult{ok: ok.ast, error: error.ast}, %{ok: ok, error: error})
  end

  def from_syn(%SynType.Tuple{elems: elems}) do
    elems
    |> Enum.map(&from_syn/1)
    |> tuple_type()
  end

  def from_syn(%SynType.Slice{inner: inner}) do
    inner = from_syn(inner)
    type(:slice, %AST.TypeSlice{inner: inner.ast}, %{inner: inner})
  end

  def from_syn(%SynType.Array{code: code, inner: inner, length: length}) do
    inner = from_syn(inner)

    ast =
      if is_binary(length),
        do: %AST.TypeArray{inner: inner.ast, size: length},
        else: %AST.TypeRaw{source: code}

    type(:array, ast, %{inner: inner, length: length})
  end

  def from_syn(%SynType.Fn{} = function) do
    args = Enum.map(function.args, &from_syn/1)
    returns = if is_nil(function.returns), do: nil, else: from_syn(function.returns)

    ast = %AST.TypeBareFn{
      args: Enum.map(args, & &1.ast),
      returns: returns && returns.ast,
      lifetimes: function.lifetimes,
      unsafe: function.unsafe,
      external: function.external,
      abi: function.abi,
      variadic: function.variadic
    }

    type(:fn, ast, %{
      args: args,
      arg_names: function.arg_names,
      returns: returns,
      lifetimes: function.lifetimes,
      unsafe: function.unsafe,
      external: function.external,
      abi: function.abi,
      variadic: function.variadic,
      variadic_name: function.variadic_name
    })
  end

  def from_syn(%SynType.Self{}), do: type(:type, %AST.TypePath{parts: [:Self]})
  def from_syn(%SynType.Raw{code: code}), do: type(:type, %AST.TypeRaw{source: code})

  def from_syn(%SynType.ImplTrait{code: code, traits: traits, bounds: bounds}) do
    trait_types = Enum.map(traits, &from_syn/1)

    ast =
      if bounds == [],
        do: %AST.TypeRaw{source: code},
        else: %AST.TypeImplTrait{bounds: Enum.map(bounds, & &1.code)}

    callable = Enum.find(traits, &match?(%SynType.Path{callable: %{}}, &1))
    metadata = %{traits: trait_types, bounds: bounds}

    metadata =
      if callable do
        Map.merge(metadata, %{
          args: Enum.map(callable.callable.args, &from_syn/1),
          returns:
            if(callable.callable.returns,
              do: from_syn(callable.callable.returns),
              else: type(:unit, %AST.TypeUnit{})
            )
        })
      else
        metadata
      end

    ast = callable_impl_ast(ast, callable, trait_types, bounds)
    type(:impl_trait, ast, metadata)
  end

  defp callable_impl_ast(ast, nil, _traits, _bounds), do: ast

  defp callable_impl_ast(ast, callable, traits, bounds) do
    kind = %{"Fn" => :fn, "FnMut" => :fn_mut, "FnOnce" => :fn_once}[callable.name]

    simple = Enum.all?(bounds, &simple_callable_bound?/1)

    lifetimes = Enum.filter(bounds, &(&1.kind == :lifetime))

    if kind && simple && not match?([_, _ | _], lifetimes) do
      %AST.TypeImplTrait{
        callable: %AST.TypeBareFn{
          args: Enum.map(callable.callable.args, &from_syn(&1).ast),
          returns: if(callable.callable.returns, do: from_syn(callable.callable.returns).ast)
        },
        kind: kind,
        traits:
          traits |> Enum.reject(&(&1.meta[:syn_name] == callable.name)) |> Enum.map(& &1.ast),
        lifetime:
          case lifetimes do
            [] -> nil
            [bound] -> bound.code |> String.trim_leading("'") |> Identifier.atom!()
          end
      }
    else
      ast
    end
  end

  defp simple_callable_bound?(%{kind: :lifetime}), do: true
  defp simple_callable_bound?(%{kind: :trait, modifier: nil, lifetimes: []}), do: true
  defp simple_callable_bound?(_bound), do: false

  defp from_syn_path(%SynType.Path{
         name: name,
         segments: segments,
         args: args,
         assoc: assoc,
         generic_args: generic_args
       }) do
    args = Enum.map(args, &from_syn/1)
    assoc = Map.new(assoc, fn {assoc_name, type} -> {assoc_name, from_syn(type)} end)
    parts = path_segments(segments, name)

    from_syn_path_parts(parts, name, args, assoc, generic_args)
  end

  defp path_segments([], name), do: [name]
  defp path_segments(segments, _name), do: segments

  defp path_kind([kind]) when kind in ~w(f32 f64 bool i8 i16 i32 i64 isize u8 u16 u32 u64 usize),
    do: String.to_existing_atom(kind)

  defp path_kind(["Atom"]), do: :atom
  defp path_kind(["Term"]), do: :term
  defp path_kind(_parts), do: :type

  defp from_syn_path_parts(["NifResult"], name, [inner], assoc, generic_args) do
    type(:nif_result, %AST.TypeNifResult{inner: inner.ast}, %{
      syn_name: name,
      syn_segments: ["NifResult"],
      args: [inner],
      assoc: assoc,
      generic_args: generic_args,
      inner: inner
    })
  end

  defp from_syn_path_parts(parts, name, args, assoc, generic_args) do
    ast = %AST.TypePath{
      parts: Enum.map(parts, &Identifier.atom!/1),
      generics: Enum.map(args, & &1.ast)
    }

    type(path_kind(parts), ast, %{
      syn_name: name,
      syn_segments: parts,
      args: args,
      assoc: assoc,
      generic_args: generic_args
    })
  end

  defp ref_kind(true), do: :mut_ref
  defp ref_kind(false), do: :ref

  defp syn_lifetime(nil), do: nil

  defp syn_lifetime("'" <> name), do: Identifier.atom!(name)

  @doc false
  @spec parse(Macro.t(), map()) :: t()
  def type_aliases(types) do
    raw =
      types
      |> List.wrap()
      |> Enum.reverse()
      |> Map.new(fn {:type, {:"::", _, [{name, _, args}, ast]}, _location} ->
        arity = type_alias_arity(args)
        rust_name = name |> Atom.to_string() |> Macro.camelize()
        {{name, arity}, {name, ast, rust_name}}
      end)

    raw
    |> Map.keys()
    |> Enum.reduce(%{}, fn key, aliases -> elem(resolve_alias(key, raw, aliases), 1) end)
  end

  defp type_alias_arity(args) when is_list(args), do: length(args)
  defp type_alias_arity(_context), do: 0

  defp resolve_alias(key, raw, aliases) do
    case Map.fetch(aliases, key) do
      {:ok, type} ->
        {type, aliases}

      :error ->
        {name, ast, rust_name} = Map.fetch!(raw, key)
        type = parse_type_alias(name, ast, rust_name, raw, aliases)
        aliases = Map.put(aliases, key, type)
        {type, aliases}
    end
  end

  defp parse_type_alias(name, ast, rust_name, raw, aliases) do
    if rust_enum_marker?(ast) do
      parse_rust_enum_alias(name, ast, rust_name, raw, aliases)
    else
      parse_standard_type_alias(name, ast, rust_name, raw, aliases)
    end
  end

  defp parse_rust_enum_alias(name, ast, rust_name, raw, aliases) do
    {variants, _aliases} = rust_enum_marker_variants!(ast, raw, aliases)

    type(:rust_enum, path(rust_name), %{
      elixir_name: name,
      rust_name: rust_name,
      variants: variants
    })
  end

  defp parse_standard_type_alias(name, ast, rust_name, raw, aliases) do
    cond do
      atom_union?(ast) ->
        type(:enum, path(rust_name), %{elixir_name: name, variants: union_members(ast)})

      option_union?(ast) ->
        [_nil, inner] = option_members(ast)
        {inner_type, _aliases} = parse_alias_type(inner, raw, aliases)

        type(:option, %AST.TypeOption{inner: inner_type.ast}, %{
          elixir_name: name,
          inner: inner_type
        })

      result_union?(ast) ->
        {ok, error} = result_members(ast)
        {ok_type, aliases} = parse_alias_type(ok, raw, aliases)
        {error_type, _aliases} = parse_alias_type(error, raw, aliases)

        type(:result, %AST.TypeResult{ok: ok_type.ast, error: error_type.ast}, %{
          elixir_name: name,
          ok: ok_type,
          error: error_type
        })

      tuple_union?(ast, raw, aliases) ->
        {variants, _aliases} = tuple_variants(ast, raw, aliases)

        type(:tuple_enum, path(rust_name), %{
          elixir_name: name,
          variants: variants
        })

      struct_type?(ast) ->
        {struct_rust_name, elixir_module, fields} = struct_type(ast)

        type(:struct, path(struct_rust_name), %{
          elixir_name: name,
          elixir_module: elixir_module,
          rust_name: struct_rust_name,
          representation: :struct,
          fields: fields
        })

      map_type?(ast) ->
        {fields, _aliases} = map_fields(ast, raw, aliases)

        type(:struct, %AST.TypePath{parts: [rust_name], lifetimes: field_lifetimes(fields)}, %{
          elixir_name: name,
          rust_name: rust_name,
          representation: :map,
          fields: fields
        })

      resource_marker?(ast) ->
        {inner, _aliases} = parse_alias_type(resource_marker_inner(ast), raw, aliases)

        target =
          type(:resource, %AST.TypePath{parts: [:ResourceArc], generics: [inner.ast]}, %{
            inner: inner
          })

        type(:resource, path(rust_name), %{
          elixir_name: name,
          target: target,
          inner: inner
        })

      true ->
        parse_standard_alias_target(name, ast, rust_name, raw, aliases)
    end
  end

  defp parse_standard_alias_target(name, ast, rust_name, raw, aliases) do
    {target_type, _aliases} = parse_alias_type(ast, raw, aliases)

    cond do
      target_type.kind == :rust_enum ->
        type(
          :rust_enum,
          path(rust_name),
          Map.merge(target_type.meta, %{elixir_name: name, rust_name: rust_name})
        )

      target_type.kind == :resource ->
        type(:resource, path(rust_name), %{
          elixir_name: name,
          target: target_type,
          inner: inner(target_type)
        })

      true ->
        type(:alias, path(rust_name), %{elixir_name: name, target: target_type})
    end
  end

  defp parse_alias_type({name, _meta, args} = ast, raw, aliases)
       when is_atom(name) and is_list(args) do
    key = {name, length(args)}

    if Map.has_key?(raw, key) do
      resolve_alias(key, raw, aliases)
    else
      {parse(ast, aliases), aliases}
    end
  end

  defp parse_alias_type(ast, _raw, aliases), do: {parse(ast, aliases), aliases}

  def parse({{:., _, [module, function]}, _, args}, aliases),
    do: parse_remote(module, function, args, aliases)

  def parse([inner], aliases), do: vector_type(inner, aliases)
  def parse([], _aliases), do: type(:vec, %AST.TypeVec{inner: path(:Term)})

  def parse({:{}, _, elements}, aliases) do
    tuple_types = Enum.map(elements, &parse(&1, aliases))
    tuple_type(tuple_types)
  end

  def parse({:|, _, _args} = union, aliases) do
    cond do
      option_union?(union) ->
        [_nil, inner] = option_members(union)
        inner_type = parse(inner, aliases)
        type(:option, %AST.TypeOption{inner: inner_type.ast})

      result_union?(union) ->
        {ok, error} = result_members(union)
        ok_type = parse(ok, aliases)
        error_type = parse(error, aliases)

        type(
          :result,
          %AST.TypeResult{ok: ok_type.ast, error: error_type.ast},
          %{ok: ok_type, error: error_type}
        )

      atom_union?(union) ->
        type(:enum, path(:Atom))

      true ->
        type(:type, path(:Term))
    end
  end

  def parse({name, _, args}, aliases) when is_atom(name) and is_list(args) do
    case Map.get(aliases, {name, length(args)}) do
      nil -> parse_local_type(name, args, aliases)
      alias_type -> alias_type
    end
  end

  def parse({:__aliases__, _, parts}, _aliases), do: type(:type, %AST.TypePath{parts: parts})

  def parse(tuple, aliases)
      when is_tuple(tuple) and tuple_size(tuple) > 0 and not is_ast_tuple(tuple) do
    tuple_types = tuple |> Tuple.to_list() |> Enum.map(&parse(&1, aliases))
    tuple_type(tuple_types)
  end

  def parse(atom, _aliases) when is_atom(atom), do: type(:type, path(atom))

  defp parse_remote(module, function, args, aliases) do
    if type_module?(module),
      do: parse_rust_type(function, args, aliases),
      else: parse_external_type(module, function, args, aliases)
  end

  defp type_module?({:__aliases__, _, [:R]}), do: true
  defp type_module?({:__aliases__, _, [:RustType]}), do: true
  defp type_module?({:__aliases__, _, [:RustQ, :Type]}), do: true
  defp type_module?(_module), do: false

  defp parse_local_type(:atom, [], _aliases), do: type(:atom, path(:Atom))
  defp parse_local_type(:boolean, [], _aliases), do: type(:bool, path(:bool))
  defp parse_local_type(:integer, [], _aliases), do: type(:i64, path(:i64))
  defp parse_local_type(:float, [], _aliases), do: type(:f64, path(:f64))
  defp parse_local_type(:number, [], _aliases), do: type(:f64, path(:f64))

  defp parse_local_type(:term, [], _aliases),
    do: type(:term, %AST.TypePath{parts: [:Term], lifetimes: [:a]})

  defp parse_local_type(:binary, [], _aliases), do: type(:binary, %AST.TypeVec{inner: path(:u8)})
  defp parse_local_type(:list, [inner], aliases), do: vector_type(inner, aliases)
  defp parse_local_type(:nonempty_list, [inner], aliases), do: vector_type(inner, aliases)
  defp parse_local_type(name, args, aliases), do: parse_rust_type(name, args, aliases)

  defp parse_rust_type(:atom, [], _aliases), do: type(:atom, path(:Atom))
  defp parse_rust_type(:bool, [], _aliases), do: type(:bool, path(:bool))
  defp parse_rust_type(:f32, [], _aliases), do: type(:f32, path(:f32))
  defp parse_rust_type(:f64, [], _aliases), do: type(:f64, path(:f64))
  defp parse_rust_type(:i8, [], _aliases), do: type(:i8, path(:i8))
  defp parse_rust_type(:i16, [], _aliases), do: type(:i16, path(:i16))
  defp parse_rust_type(:i32, [], _aliases), do: type(:i32, path(:i32))
  defp parse_rust_type(:i64, [], _aliases), do: type(:i64, path(:i64))
  defp parse_rust_type(:isize, [], _aliases), do: type(:isize, path(:isize))
  defp parse_rust_type(:str, [], _aliases), do: type(:str, %AST.TypeRef{inner: path(:str)})

  defp parse_rust_type(:term, [], _aliases),
    do: type(:term, %AST.TypePath{parts: [:Term], lifetimes: [:a]})

  defp parse_rust_type(:u8, [], _aliases), do: type(:u8, path(:u8))
  defp parse_rust_type(:u16, [], _aliases), do: type(:u16, path(:u16))
  defp parse_rust_type(:u32, [], _aliases), do: type(:u32, path(:u32))
  defp parse_rust_type(:u64, [], _aliases), do: type(:u64, path(:u64))
  defp parse_rust_type(:usize, [], _aliases), do: type(:usize, path(:usize))
  defp parse_rust_type(:unit, [], _aliases), do: type(:unit, %AST.TypeUnit{})

  defp parse_rust_type(:impl, [signature], aliases),
    do: parse_rust_type(:impl, [signature, []], aliases)

  defp parse_rust_type(:impl, [[{:->, _, [args, returns]}], opts], aliases) do
    validate_impl_options!(opts)

    kind = Keyword.get(opts, :kind, :fn)

    unless kind in [:fn, :fn_mut, :fn_once],
      do: raise(ArgumentError, "invalid R.impl callable kind")

    args = Enum.map(args, &parse(&1, aliases))
    returns = parse(returns, aliases)
    trait_options = Keyword.get(opts, :traits, [])
    unless is_list(trait_options), do: raise(ArgumentError, "R.impl traits must be a list")
    traits = Enum.map(trait_options, &parse(&1, aliases).ast)

    unless Enum.all?(traits, &match?(%AST.TypePath{}, &1)),
      do: raise(ArgumentError, "R.impl traits must be Rust trait paths")

    lifetime =
      case Keyword.get(opts, :lifetime) do
        nil ->
          nil

        {{:., _, [module, :lifetime]}, _, [name]} when is_atom(name) ->
          unless type_module?(module), do: raise(ArgumentError, "expected R.lifetime(name)")
          name

        _ ->
          raise ArgumentError, "expected R.lifetime(name)"
      end

    ast = %AST.TypeImplTrait{
      callable: %AST.TypeBareFn{args: Enum.map(args, & &1.ast), returns: returns.ast},
      kind: kind,
      traits: traits,
      lifetime: lifetime
    }

    type(:impl_trait, ast, %{args: args, returns: returns, traits: []})
  end

  defp parse_rust_type(:impl, _args, _aliases),
    do: raise(ArgumentError, "R.impl expects an ordinary Elixir function type")

  defp parse_rust_type(:path, [parts], aliases), do: parse_path_type(parts, nil, aliases)
  defp parse_rust_type(:path, [parts, opts], aliases), do: parse_path_type(parts, opts, aliases)

  defp parse_rust_type(:lifetime, [name], _aliases),
    do: type(:lifetime, {:raw, "'#{spec_path_part!(name)}"})

  defp parse_rust_type(:slice, [inner], aliases) do
    inner = parse(inner, aliases)
    type(:slice, %AST.TypeRef{inner: %AST.TypeSlice{inner: inner.ast}}, %{inner: inner})
  end

  defp parse_rust_type(:raw, [type], _aliases), do: type(:type, raw_type!(type))

  defp parse_rust_type(:enum, [variants], aliases) when is_list(variants) do
    type(:rust_enum, path(:Enum), %{variants: rust_enum_variants!(variants, aliases)})
  end

  defp parse_rust_type(:enum, [name], _aliases) do
    enum = spec_path_part!(name)
    type(:enum, path(enum), %{enum: enum})
  end

  defp parse_rust_type(:ref, [inner], aliases) do
    inner = parse(inner, aliases)
    type(:ref, %AST.TypeRef{inner: inner.ast}, %{inner: inner})
  end

  defp parse_rust_type(:mut_ref, [inner], aliases) do
    inner = parse(inner, aliases)
    type(:mut_ref, %AST.TypeRef{inner: inner.ast, mutable: true}, %{inner: inner})
  end

  defp parse_rust_type(:option, [inner], aliases) do
    inner = parse(inner, aliases)
    type(:option, %AST.TypeOption{inner: inner.ast}, %{inner: inner})
  end

  defp parse_rust_type(:vec, [inner], aliases), do: vector_type(inner, aliases)

  defp parse_rust_type(:resource, [inner], aliases) do
    inner = parse(inner, aliases)

    type(
      :resource,
      %AST.TypePath{parts: [:ResourceArc], generics: [inner.ast]},
      %{inner: inner}
    )
  end

  defp parse_rust_type(:result, [ok, error], aliases) do
    ok = parse(ok, aliases)
    error = parse(error, aliases)
    type(:result, %AST.TypeResult{ok: ok.ast, error: error.ast}, %{ok: ok, error: error})
  end

  defp parse_rust_type(:nif_result, [inner], aliases) do
    inner = parse(inner, aliases)
    type(:nif_result, %AST.TypeNifResult{inner: inner.ast}, %{inner: inner})
  end

  defp parse_rust_type(function, args, aliases) do
    type(:type, %AST.TypePath{
      parts: [function],
      generics: Enum.map(args, &parse(&1, aliases).ast)
    })
  end

  defp validate_impl_options!(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "R.impl expects keyword options")
    keys = Keyword.keys(opts)

    unless keys -- [:kind, :traits, :lifetime] == [] and keys == Enum.uniq(keys),
      do: raise(ArgumentError, "R.impl expects unique kind, traits, and lifetime options")
  end

  defp vector_type(inner, aliases) do
    inner = parse(inner, aliases)
    type(:vec, %AST.TypeVec{inner: inner.ast}, %{inner: inner})
  end

  defp parse_external_type({:__aliases__, _, parts}, :t, args, aliases) do
    type(:type, external_type_path(parts, args, aliases), external_type_meta(parts, :t, args))
  end

  defp parse_external_type({:__aliases__, _, parts}, function, args, aliases) do
    type =
      case args do
        [] ->
          %AST.TypePath{parts: external_type_parts(parts) ++ [function]}

        args ->
          %AST.TypePath{
            parts: external_type_parts(parts) ++ [function],
            lifetimes: Enum.flat_map(args, &external_type_lifetimes!/1),
            generics: Enum.flat_map(args, &external_type_generics(&1, aliases))
          }
      end

    type(:type, type, external_type_meta(parts, function, args))
  end

  defp parse_external_type(_module, function, _args, _aliases), do: type(:type, path(function))

  defp parse_path_type(parts, opts, aliases) do
    ast = spec_path!(parts, opts)
    path_alias_type(ast, aliases) || type(:type, ast)
  end

  defp path_alias_type(%AST.TypePath{} = ast, aliases) do
    rust = Rust.render_type(ast)

    Enum.find_value(aliases, fn
      {_key, %__MODULE__{meta: %{rust_name: ^rust}} = alias_type} -> alias_type
      {_key, %__MODULE__{rust: ^rust} = alias_type} -> alias_type
      _alias -> nil
    end)
  end

  defp spec_path!({:__block__, _, [parts]}, opts), do: spec_path!(parts, opts)

  defp spec_path!({:{}, _, parts}, opts), do: spec_path_tuple!(parts, opts)

  defp spec_path!(parts, opts) when is_tuple(parts) do
    parts |> Tuple.to_list() |> spec_path_tuple!(opts)
  end

  defp spec_path!(part, opts) when is_atom(part), do: spec_path!({part}, opts)

  defp spec_path!(other, _opts) do
    raise ArgumentError, "expected R.path parts tuple, got: #{Macro.to_string(other)}"
  end

  defp spec_path_tuple!(parts, opts) do
    %AST.TypePath{
      parts: Enum.map(parts, &spec_path_part!/1),
      lifetimes: spec_path_lifetimes!(opts)
    }
  end

  defp spec_path_lifetimes!(nil), do: []

  defp spec_path_lifetimes!({{:., _, [module, :lifetime]}, _, [name]}) do
    if type_module?(module), do: [spec_path_part!(name)], else: []
  end

  defp spec_path_lifetimes!(other) do
    raise ArgumentError,
          "expected R.path option such as R.lifetime(:a), got: #{Macro.to_string(other)}"
  end

  defp spec_path_part!(part) when is_atom(part), do: part
  defp spec_path_part!(part) when is_binary(part), do: Identifier.atom!(part)

  defp spec_path_part!(other) do
    raise ArgumentError,
          "expected R.path part to be an atom or string, got: #{Macro.to_string(other)}"
  end

  defp raw_type!({:__block__, _, [type]}), do: raw_type!(type)
  defp raw_type!(type) when is_atom(type), do: %AST.TypeRaw{source: Atom.to_string(type)}
  defp raw_type!(type) when is_binary(type), do: %AST.TypeRaw{source: type}

  defp raw_type!(other) do
    raise ArgumentError, "expected R.raw atom marker or string, got: #{Macro.to_string(other)}"
  end

  defp resource_marker?({{:., _, [module, :resource]}, _, [_inner]}),
    do: type_module?(module)

  defp resource_marker?(_ast), do: false

  defp resource_marker_inner({{:., _, [_module, :resource]}, _, [inner]}), do: inner

  defp rust_enum_marker?({{:., _, [module, :enum]}, _, [variants]}) when is_list(variants),
    do: type_module?(module)

  defp rust_enum_marker?(_ast), do: false

  defp rust_enum_marker_variants!({{:., _, [_module, :enum]}, _, [variants]}, raw, aliases) do
    Enum.map_reduce(variants, aliases, fn
      {name, tuple_types}, aliases when is_atom(name) and is_list(tuple_types) ->
        {types, aliases} = Enum.map_reduce(tuple_types, aliases, &parse_alias_type(&1, raw, &2))
        {{name, types}, aliases}

      other, _aliases ->
        raise ArgumentError,
              "expected R.enum variants as keyword entries with type lists, got: #{inspect(other)}"
    end)
  end

  defp rust_enum_variants!(variants, aliases) do
    Enum.map(variants, fn
      {name, tuple_types} when is_atom(name) and is_list(tuple_types) ->
        {name, Enum.map(tuple_types, &parse(&1, aliases))}

      other ->
        raise ArgumentError,
              "expected R.enum variants as keyword entries with type lists, got: #{inspect(other)}"
    end)
  end

  defp external_type_path(parts, args, aliases) do
    %AST.TypePath{
      parts: external_type_parts(parts),
      lifetimes: Enum.flat_map(args, &external_type_lifetimes!/1),
      generics: Enum.flat_map(args, &external_type_generics(&1, aliases))
    }
  end

  defp external_type_meta(parts, function, args) do
    %{
      elixir_module: Module.concat(parts),
      elixir_type: function,
      elixir_args: args
    }
  end

  defp external_type_parts([part]), do: [part]
  defp external_type_parts([:"Elixir" | parts]), do: [List.last(parts)]
  defp external_type_parts([:RustQ | parts]), do: [List.last(parts)]

  defp external_type_parts(parts) do
    {modules, [type]} = Enum.split(parts, -1)
    Enum.map(modules, &rust_module_part/1) ++ [type]
  end

  defp external_type_lifetimes!({{:., _, [module, :lifetime]}, _, [name]}) do
    if type_module?(module), do: [spec_path_part!(name)], else: []
  end

  defp external_type_lifetimes!(_arg), do: []

  defp external_type_generics({{:., _, [module, :lifetime]}, _, [_name]}, _aliases) do
    if type_module?(module), do: [], else: raise(ArgumentError, "unsupported lifetime marker")
  end

  defp external_type_generics(arg, aliases), do: [parse(arg, aliases).ast]

  defp rust_module_part(part) when is_atom(part),
    do: Identifier.atom!(Macro.underscore(Atom.to_string(part)))

  defp rust_module_part(part) when is_binary(part), do: Macro.underscore(part)

  @doc false
  @spec ast_type(AST.type()) :: t()
  def ast_type(ast), do: type(ast_type_kind(ast), ast)

  defp ast_type_kind(%AST.TypeNifResult{}), do: :nif_result
  defp ast_type_kind(%AST.TypeResult{}), do: :result
  defp ast_type_kind(%AST.TypeOption{}), do: :option
  defp ast_type_kind(%AST.TypePath{parts: [kind]}) when kind in @number_kinds, do: kind
  defp ast_type_kind(%AST.TypePath{parts: [kind]}) when kind in @integer_kinds, do: kind
  defp ast_type_kind(%AST.TypePath{parts: [:bool]}), do: :bool
  defp ast_type_kind(%AST.TypePath{parts: [:Atom]}), do: :atom
  defp ast_type_kind(%AST.TypePath{parts: [:Term]}), do: :term
  defp ast_type_kind(_ast), do: :type

  defp tuple_type(tuple_types) do
    ast = %AST.TypeTuple{items: Enum.map(tuple_types, & &1.ast)}
    type(:tuple, ast, %{elements: tuple_types})
  end

  defp struct_type?({:%, _, [{:__aliases__, _, _parts}, {:%{}, _, fields}]}) when is_list(fields),
    do: true

  defp struct_type?(_ast), do: false

  defp struct_type({:%, _, [{:__aliases__, _, parts}, {:%{}, _, fields}]}) do
    rust_name = parts |> List.last() |> to_string()

    fields =
      Enum.map(fields, fn {name, ast} ->
        {name, parse(ast, %{}), :required}
      end)

    {rust_name, Module.concat(parts), fields}
  end

  defp map_type?({:%{}, _, fields}) when is_list(fields), do: true
  defp map_type?(_ast), do: false

  defp field_lifetimes(fields) do
    if Enum.any?(fields, fn {_name, type, _presence} -> lifetime?(type) end),
      do: [:a],
      else: []
  end

  defp map_fields({:%{}, _, fields}, raw, aliases) do
    Enum.map_reduce(fields, aliases, fn
      {{:required, _, [name]}, ast}, aliases ->
        {type, aliases} = parse_alias_type(ast, raw, aliases)
        {{name, type, :required}, aliases}

      {{:optional, _, [name]}, ast}, aliases ->
        {type, aliases} = parse_alias_type(ast, raw, aliases)
        {{name, type, :optional}, aliases}
    end)
  end

  defp union_members(ast), do: collect_union_members(ast, [])

  defp collect_union_members({:|, _, [left, right]}, acc) do
    acc = collect_union_members(right, acc)
    collect_union_members(left, acc)
  end

  defp collect_union_members({:|, _, [members]}, acc) when is_list(members) do
    members
    |> Enum.reverse()
    |> Enum.reduce(acc, &collect_union_members/2)
  end

  defp collect_union_members(other, acc), do: [other | acc]

  defp atom_union?(ast), do: ast |> union_members() |> Enum.all?(&is_atom/1)

  defp option_union?(ast), do: ast |> union_members() |> option_members?()

  defp option_members(ast),
    do:
      (
        members = union_members(ast)
        [nil, Enum.find(members, &(&1 != nil))]
      )

  defp result_union?(ast) do
    ast
    |> union_members()
    |> result_members?()
  end

  defp option_members?([left, right]), do: is_nil(left) or is_nil(right)
  defp option_members?(_members), do: false

  defp result_members?([left, right]) do
    (result_member?(left, :ok) and result_member?(right, :error)) or
      (result_member?(left, :error) and result_member?(right, :ok))
  end

  defp result_members?(_members), do: false

  defp result_member?({tag, _type}, tag), do: true
  defp result_member?({:{}, _, [tag, _type]}, tag), do: true
  defp result_member?(_member, _tag), do: false

  defp tuple_union?({:|, _, _} = ast, raw, aliases),
    do: ast |> union_members() |> Enum.all?(&tagged_tuple?(&1, raw, aliases))

  defp tuple_union?(_ast, _raw, _aliases), do: false

  defp tagged_tuple?({name, _, args}, raw, aliases) when is_atom(name) and is_list(args) do
    {type, _aliases} = parse_alias_type({name, [], args}, raw, aliases)
    type.kind == :struct
  rescue
    _error in [ArgumentError, FunctionClauseError] -> false
  end

  defp tagged_tuple?(_other, _raw, _aliases), do: false

  defp tuple_variants(ast, raw, aliases) do
    ast
    |> union_members()
    |> Enum.map_reduce(aliases, &tuple_variant(&1, raw, &2))
  end

  defp tuple_variant({name, _, args}, raw, aliases) when is_atom(name) and is_list(args) do
    {type, aliases} = parse_alias_type({name, [], args}, raw, aliases)
    {{Identifier.atom!(type.meta.rust_name), [type]}, aliases}
  end

  defp result_members(ast) do
    members = union_members(ast)
    {result_member_type(members, :ok), result_member_type(members, :error)}
  end

  defp result_member_type(members, tag) do
    Enum.find_value(members, fn
      {^tag, type} -> type
      {:{}, _, [^tag, type]} -> type
      _member -> nil
    end)
  end

  defp path(part), do: %AST.TypePath{parts: [part]}

  defp type(kind, ast, meta \\ %{}) do
    %__MODULE__{
      kind: kind,
      ast: ast,
      rust: Rust.render_type(ast),
      meta: meta
    }
  end
end
