defmodule RustQ.Rustler.Term do
  @moduledoc """
  Generates Rustler `Term<'a>` builders, decoders, and map access helpers.

  Most helpers are authored with `defrust` or RustQ AST. The remaining
  `EscapeExpr` fragments are localized Rustler wrapper-boundary escapes for
  unsafe raw term construction or caller-supplied decoder expressions.
  """

  use RustQ.Meta

  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.ItemBuilder, as: I
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.TypeBuilder, as: T
  alias RustQ.Rust.Identifier
  alias RustQ.Rustler.HelperSelection
  alias RustQ.Rustler.SourceEncoder
  alias RustQ.Type, as: R

  require A
  require I

  defmodule EncoderField do
    @moduledoc false
    @enforce_keys [:key, :source, :mode]
    defstruct [:key, :source, :mode, :via, :with, :map, :optional, :fallback, borrow: true]
  end

  @builder_names [:map_from_terms, :struct_from_terms]
  @builder_function_names %{
    map_from_terms: :make_map_from_terms,
    struct_from_terms: :make_struct_from_terms
  }

  @helper_names [
    :cached_struct_keys,
    :default_struct_values,
    :get,
    :is_nil,
    :make_struct_from_nif_term_arrays,
    :opt,
    :str_val,
    :bool_val,
    :f64_val,
    :list_val,
    :get_bool,
    :get_i64,
    :get_string,
    :get_optional_string,
    :get_string_list,
    :get_term_list,
    :get_map,
    :type_atom,
    :type_eq,
    :type_str
  ]

  @rusty_helper_names @helper_names

  @spec cached_struct_keys(
          R.raw(:"Env<'_>"),
          R.raw(:"&'static OnceLock<Vec<rustler::wrapper::NIF_TERM>>"),
          R.raw(:"&[&str]")
        ) :: R.raw(:"&'static [rustler::wrapper::NIF_TERM]")
  defrust cached_struct_keys(env, cache, fields) do
    cache.get_or_init(fn ->
      keys = Vec.with_capacity(fields.len() + 1)
      keys.push(Atom.from_str(env, "__struct__").unwrap().as_c_arg())

      for field <- fields do
        keys.push(Atom.from_str(env, field).unwrap().as_c_arg())
      end

      keys
    end)
  end

  @spec default_struct_values(R.path(:Env, R.lifetime(:_)), R.path(:Atom), R.usize()) ::
          R.vec(R.path({:rustler, :wrapper, :NIF_TERM}))
  defrust default_struct_values(env, module, len) do
    values = Vec.with_capacity(len + 1)
    values.resize(len + 1, Atom.from_str(env, "nil").unwrap().as_c_arg())
    assign!(index(values, 0), module.as_c_arg())
    values
  end

  @spec make_map_from_terms(R.path(:Env, R.lifetime(:a)), R.slice({term(), term()})) ::
          R.nif_result(term())
  defrust make_map_from_terms(env, pairs) do
    keys = Vec.with_capacity(pairs.len())
    values = Vec.with_capacity(pairs.len())

    for {key, value} <- pairs.iter().copied() do
      keys.push(key)
      values.push(value)
    end

    Term.map_from_term_arrays(env, ref(keys), ref(values))
  end

  @spec make_struct_from_terms(R.path(:Env, R.lifetime(:a)), R.slice(term()), R.slice(term())) ::
          R.nif_result(term())
  defrust make_struct_from_terms(env, keys, values) do
    Term.map_from_term_arrays(env, keys, values)
  end

  @spec get(term(), R.path({:rustler, :Atom})) :: R.option(term())
  defrust get(term, key) do
    term.map_get(key).ok()
  end

  @spec is_nil(term()) :: boolean()
  defrust is_nil(term) do
    if term.is_atom() do
      case term.atom_to_string() do
        {:ok, value} -> value == "nil"
        {:error, _reason} -> false
      end
    else
      false
    end
  end

  @spec opt(term(), R.path({:rustler, :Atom})) :: R.option(term())
  defrust(opt(term, key)) do
    get(term, key).filter(fn value -> not is_nil(deref(value)) end)
  end

  @spec str_val(term(), R.path({:rustler, :Atom})) :: String.t()
  defrust str_val(term, key) do
    case get(term, key) do
      {:some, value} ->
        case decode_as(value, String.t()) do
          {:ok, decoded} ->
            decoded

          {:error, _reason} ->
            value.atom_to_string().unwrap_or_default()
        end

      :none ->
        String.new()
    end
  end

  @spec bool_val(term(), R.path({:rustler, :Atom})) :: boolean()
  defrust bool_val(term, key) do
    case get(term, key) do
      {:some, value} ->
        value.decode().unwrap_or_default()

      :none ->
        false
    end
  end

  @spec f64_val(term(), R.path({:rustler, :Atom})) :: R.f64()
  defrust f64_val(term, key) do
    case get(term, key) do
      {:some, value} ->
        case decode_as(value, R.f64()) do
          {:ok, decoded} ->
            decoded

          {:error, _reason} ->
            case decode_as(value, R.i64()) do
              {:ok, decoded} -> cast(decoded, :f64)
              {:error, _reason} -> 0.0
            end
        end

      :none ->
        0.0
    end
  end

  @spec list_val(term(), R.path({:rustler, :Atom})) :: R.vec(term())
  defrust list_val(term, key) do
    case get(term, key) do
      {:some, value} ->
        value.decode().unwrap_or_default()

      :none ->
        Vec.new()
    end
  end

  @spec get_bool(term(), R.path({:rustler, :Atom})) :: R.option(boolean())
  defrust get_bool(term, key) do
    case get(term, key) do
      {:some, value} ->
        decode_as(value, boolean()).ok()

      :none ->
        nil
    end
  end

  @spec get_i64(term(), R.path({:rustler, :Atom})) :: R.option(R.i64())
  defrust get_i64(term, key) do
    case get(term, key) do
      {:some, value} ->
        decode_as(value, R.i64()).ok()

      :none ->
        nil
    end
  end

  @spec get_string(term(), R.path({:rustler, :Atom})) :: R.option(String.t())
  defrust get_string(term, key) do
    case get(term, key) do
      {:some, value} ->
        case decode_as(value, String.t()) do
          {:ok, decoded} ->
            decoded

          {:error, _reason} ->
            value.atom_to_string().ok()
        end

      :none ->
        nil
    end
  end

  @spec get_optional_string(term(), R.path({:rustler, :Atom})) ::
          R.option(R.option(String.t()))
  defrust get_optional_string(term, key) do
    case get(term, key) do
      {:some, value} ->
        if is_nil(value) do
          some(none())
        else
          get_string(term, key).map(Some)
        end

      :none ->
        none()
    end
  end

  @spec get_string_list(term(), R.path({:rustler, :Atom})) :: R.option(R.vec(String.t()))
  defrust get_string_list(term, key) do
    case get(term, key) do
      {:some, value} ->
        decode_as(value, R.vec(String.t())).ok()

      :none ->
        nil
    end
  end

  @spec get_term_list(term(), R.path({:rustler, :Atom})) :: R.option(R.vec(term()))
  defrust get_term_list(term, key) do
    case get(term, key) do
      {:some, value} ->
        decode_as(value, R.vec(term())).ok()

      :none ->
        nil
    end
  end

  @spec get_map(term(), R.path({:rustler, :Atom})) :: R.option(term())
  defrust(get_map(term, key)) do
    get(term, key).filter(fn value -> value.is_map() end)
  end

  @spec type_atom(term()) :: R.option(R.path({:rustler, :Atom}))
  defrust type_atom(term) do
    case get(term, Atoms.type()) do
      {:some, value} ->
        decode_as(value, R.path({:rustler, :Atom})).ok()

      :none ->
        nil
    end
  end

  @spec type_eq(term(), R.path({:rustler, :Atom})) :: boolean()
  defrust type_eq(term, expected) do
    type_atom(term) == some(expected)
  end

  @spec type_str(term()) :: String.t()
  defrust type_str(term) do
    case get(term, Atoms.type()) do
      {:some, value} ->
        case value.atom_to_string() do
          {:ok, decoded} -> decoded
          {:error, _reason} -> String.from("<no type>")
        end

      :none ->
        String.from("<no type>")
    end
  end

  @doc "Builds safe `Term<'a>` map and struct construction helpers."
  @spec builders(keyword()) :: [AST.Function.t()]
  def builders(opts \\ []) do
    opts
    |> HelperSelection.names(@builder_names)
    |> Enum.map(&builder_item/1)
  end

  @doc "Builds a struct and decoder from an atom-keyed Rustler map term."
  @spec decoder(atom() | String.t(), keyword()) :: [AST.Struct.t() | AST.Function.t()]
  def decoder(name, opts) do
    lifetime = Keyword.get(opts, :lifetime, :a)
    fields = Keyword.fetch!(opts, :fields)
    function_name = Keyword.get(opts, :fn, default_decoder_name(name))
    term_arg = Keyword.get(opts, :term_arg, :term)
    term_type = Keyword.get(opts, :term_type, "Term<'#{lifetime}>")

    result = Keyword.get(opts, :result, :nif)
    result_type = result_type(name, lifetime, result)

    [
      struct_ast(name, fields, lifetime),
      decoder_ast(name, function_name, fields, term_arg, term_type, result_type, result, lifetime)
    ]
  end

  @doc "Returns the Rust atom identifiers referenced by a term encoder manifest."
  @spec encoder_atom_names(keyword()) :: [String.t()]
  def encoder_atom_names(opts) do
    opts
    |> Keyword.fetch!(:fields)
    |> Enum.map(&encoder_field/1)
    |> Enum.map(&to_string(&1.key))
    |> Enum.uniq()
  end

  @doc "Builds a `rustler::Encoder` implementation from structural field metadata."
  @spec encoder(atom() | String.t(), keyword()) :: AST.Impl.t()
  def encoder(name, opts) do
    fields = opts |> Keyword.fetch!(:fields) |> Enum.map(&encoder_field/1)

    function = %AST.Function{
      name: :encode,
      lifetimes: [:a],
      args: [A.receiver(), A.arg(:env, A.type_path([:rustler, :Env], lifetimes: [:a]))],
      returns: A.type_path([:rustler, :Term], lifetimes: [:a]),
      body: encoder_body(fields)
    }

    target =
      A.type_path(ident_atom(name), lifetimes: Keyword.get(opts, :target_lifetimes, []))

    A.impl(target,
      trait: A.type_path([:rustler, :Encoder]),
      items: [function]
    )
  end

  @doc """
  Builds `Term` encoder functions for Rust structs and enums read from source.

  `source` is a `RustQ.Syn.Index` or a list of Rust source paths. Starting from
  `roots`, RustQ follows field and variant payload types through the index and
  builds one function per reachable type:

      pub(crate) fn encode_set_prop_ir_node<'a>(env: Env<'a>, value: &SetPropIRNode<'_>) -> Term<'a>

  Free functions keep the encoders usable for types owned by another crate.
  Structs encode as atom-keyed maps. A newtype struct encodes as its single
  field. Unit variants encode as atoms, tuple variants as their payload, and
  named variants as maps. `Option` encodes `None` as `nil`, sequences and sets
  as lists, and maps as maps.

  Every reachable type must be indexed, a wrapper, a scalar, or mapped in
  `:external`. Otherwise the call raises and lists the unmapped types, so a
  change in the source shows up at generation time.

  Options:

  - `:tag` — key added to data-carrying enum variants, with the variant atom
    (`SetProp` becomes `:set_prop`) as its value.
  - `:external` — `[{type_name, helper}]`; the helper is called with the
    environment and a reference to the value instead of generating an encoder.
  - `:wrappers` — type names added to the `:pointer`, `:sequence`, `:set`,
    `:map`, and `:string` roles, for example allocator-aware `Vec` types.
  - `:types` — per-type policy: `:except` field names, `:fields` with `:key`
    renames or `:with` helpers, `:variants` atom renames, and `:tag`.
  - `:vis` — function visibility, `:crate` by default.
  """
  @spec encoders_from_source(RustQ.Syn.Index.t() | [Path.t()], [atom() | String.t()], keyword()) ::
          [AST.Function.t()]
  def encoders_from_source(source, roots, opts \\ []),
    do: SourceEncoder.functions(source, roots, opts)

  @doc """
  Returns the atom declarations used by `encoders_from_source/3`.

  Pass the result to `RustQ.Rustler.Atom.declaration/2` so the atom registry is
  derived from the same source as the encoders.
  """
  @spec encoder_atoms_from_source(
          RustQ.Syn.Index.t() | [Path.t()],
          [atom() | String.t()],
          keyword()
        ) :: [String.t() | {atom(), String.t()}]
  def encoder_atoms_from_source(source, roots, opts \\ []),
    do: SourceEncoder.atoms(source, roots, opts)

  @doc "Builds common map access and term decoding helpers."
  @spec helpers(keyword()) :: [AST.Function.t()]
  def helpers(opts \\ []) do
    opts
    |> HelperSelection.names(@helper_names)
    |> Enum.map(&helper_item/1)
  end

  defp encoder_field(field) when is_atom(field),
    do: %EncoderField{key: field, source: [field], mode: :required}

  defp encoder_field({key, field}) when is_atom(key) and is_atom(field),
    do: %EncoderField{key: key, source: [field], mode: :required}

  defp encoder_field({key, opts}) when is_atom(key) and is_list(opts) do
    mode = if Keyword.get(opts, :when_some, false), do: :when_some, else: :required

    %EncoderField{
      key: key,
      source: opts |> Keyword.get(:field, key) |> List.wrap(),
      mode: mode,
      via: Keyword.get(opts, :via),
      with: Keyword.get(opts, :with),
      map: Keyword.get(opts, :map),
      optional: Keyword.get(opts, :optional),
      fallback: Keyword.get(opts, :fallback),
      borrow: Keyword.get(opts, :borrow, true)
    }
  end

  defp encoder_body(fields) do
    {conditional, required} = Enum.split_with(fields, &(&1.mode == :when_some))

    if conditional == [] do
      [A.return(A.method(encoder_map_call(required, :array), :unwrap))]
    else
      [
        A.let_mut(:keys, A.vec(Enum.map(required, &encoded_atom(&1.key)))),
        A.let_mut(:values, A.vec(Enum.map(required, &encoded_field/1)))
        | Enum.map(conditional, &conditional_encoder_field/1)
      ] ++ [A.return(A.method(encoder_map_call([], :vectors), :unwrap))]
    end
  end

  defp conditional_encoder_field(%EncoderField{key: key, source: source} = field) do
    A.if_let(
      P.some(P.var(:value)),
      A.method(field_source(source), :as_ref),
      [
        %AST.ExprStmt{expr: A.method(:keys, :push, [encoded_atom(key)])},
        %AST.ExprStmt{expr: A.method(:values, :push, [encoded_optional_value(field)])}
      ]
    )
  end

  defp encoded_optional_value(%EncoderField{via: via, with: helper}) do
    value = apply_encoder_via(A.var(:value), via)

    if helper do
      A.path_call(List.wrap(helper), [:env, A.ref(value)])
    else
      A.method(value, :encode, [:env])
    end
  end

  defp encoder_map_call(fields, :array) do
    keys = Enum.map(fields, &encoded_atom(&1.key))
    values = Enum.map(fields, &encoded_field/1)
    encoder_map_call(A.array(keys), A.array(values))
  end

  defp encoder_map_call([], :vectors), do: encoder_map_call(:keys, :values)

  defp encoder_map_call(keys, values) do
    A.path_call([:Term, :map_from_arrays], [:env, A.ref(keys), A.ref(values)])
  end

  defp encoded_atom(key), do: A.method(A.path_call([:atoms, key]), :encode, [:env])

  defp encoded_field(%EncoderField{source: source, map: map}) when is_list(map) do
    source
    |> field_source()
    |> A.method(:iter)
    |> A.method(:map, [A.closure([:value], adapted_term(A.var(:value), map))])
    |> A.method(:collect, [],
      generics: [A.type_path(:Vec, generics: [A.type_path(:Term, lifetimes: [:a])])]
    )
    |> A.method(:encode, [:env])
  end

  defp encoded_field(%EncoderField{source: source, optional: optional})
       when is_list(optional) do
    source
    |> field_source()
    |> A.method(:as_ref)
    |> A.method(:map, [A.closure([:value], adapted_term(A.var(:value), optional))])
    |> A.method(:unwrap_or_else, [A.closure([], A.call(:nil_term, [:env]))])
  end

  defp encoded_field(%EncoderField{} = field) do
    value =
      field.source
      |> field_source()
      |> apply_encoder_fallback(field.fallback)
      |> apply_encoder_via(field.via)

    if field.with do
      argument = if field.borrow, do: A.ref(value), else: value
      A.path_call(List.wrap(field.with), [:env, argument])
    else
      A.method(value, :encode, [:env])
    end
  end

  defp apply_encoder_fallback(value, nil), do: value

  defp apply_encoder_fallback(value, opts) do
    fallback =
      opts
      |> Keyword.fetch!(:field)
      |> List.wrap()
      |> field_source()
      |> apply_encoder_via(Keyword.get(opts, :via))

    A.method(value, :unwrap_or, [fallback])
  end

  defp adapted_term(value, opts) do
    cond do
      helper = Keyword.get(opts, :with) ->
        A.path_call(List.wrap(helper), [:env, value])

      wrapper = Keyword.get(opts, :wrap) ->
        A.method(A.call(wrapper, [value]), :encode, [:env])

      converter = Keyword.get(opts, :convert) ->
        converter
        |> then(&A.path_call([&1, :from], [value]))
        |> A.method(:encode, [:env])

      via = Keyword.get(opts, :via) ->
        value |> A.method(via) |> A.method(:encode, [:env])

      true ->
        A.method(value, :encode, [:env])
    end
  end

  defp field_source(source), do: Enum.reduce(source, A.var(:self), &A.field(&2, &1))
  defp apply_encoder_via(value, nil), do: value
  defp apply_encoder_via(value, method), do: A.method(value, method)

  defp builder_item(name) do
    function_name = Map.fetch!(@builder_function_names, name)
    MetaAST.function!(__MODULE__, function_name)
  end

  defp helper_item(:make_struct_from_nif_term_arrays), do: make_struct_from_nif_term_arrays_item()

  defp helper_item(name) when name in @rusty_helper_names,
    do: MetaAST.function!(__MODULE__, name)

  defp make_struct_from_nif_term_arrays_item do
    make_map =
      [:rustler, :wrapper, :map, :make_map_from_arrays]
      |> A.path_call([A.method(:env, :as_c_arg), :keys, :values])
      |> A.method(:map, [A.closure([:term], A.path_call([:Term, :new], [:env, :term]))])
      |> A.method(:ok_or, [A.badarg()])

    result =
      A.if_expr(
        A.eq(A.method(:keys, :len), A.method(:values, :len)),
        [A.return_stmt(A.unsafe_block([A.return_stmt(make_map)]))],
        [A.return_stmt(A.err(A.badarg()))]
      )

    %AST.Function{
      name: :make_struct_from_nif_term_arrays,
      lifetimes: [:a],
      args: [
        A.arg(:env, "Env<'a>"),
        A.arg(:keys, "&[rustler::wrapper::NIF_TERM]"),
        A.arg(:values, "&[rustler::wrapper::NIF_TERM]")
      ],
      returns: T.raw("NifResult<Term<'a>>"),
      body: [A.return_stmt(result)]
    }
  end

  defp struct_ast(name, fields, lifetime) do
    I.struct ident_atom(name), lifetimes: List.wrap(lifetime) do
      struct_fields(fields)
    end
  end

  defp decoder_ast(
         name,
         function_name,
         fields,
         term_arg,
         term_type,
         result_type,
         result,
         lifetime
       ) do
    %AST.Function{
      name: ident_atom(function_name),
      lifetimes: List.wrap(lifetime),
      args: [A.arg(ident_atom(term_arg), term_type)],
      returns: T.type(result_type),
      body: [
        A.return_stmt(
          A.ok(A.struct_expr(A.path(ident_atom(name)), decoder_inits(fields, term_arg, result)))
        )
      ]
    }
  end

  defp struct_fields(fields) do
    Enum.map(fields, fn {field_name, spec} ->
      I.field(field_name, Keyword.fetch!(spec, :type), vis: nil)
    end)
  end

  defp decoder_inits(fields, term_arg, result) do
    Enum.map(fields, fn {field_name, spec} ->
      spec = Keyword.put_new(spec, :field, field_name)
      {field_name, decoder_expr(spec, term_arg, result)}
    end)
  end

  defp decoder_expr(spec, term_arg, result) do
    cond do
      decode = Keyword.get(spec, :decode) ->
        source_expr(decode)

      Keyword.get(spec, :required, false) ->
        required_expr(spec, term_arg, result)

      Keyword.has_key?(spec, :default) ->
        spec
        |> optional_decode(term_arg, Keyword.fetch!(spec, :type))
        |> A.method(:unwrap_or, [source_expr(Keyword.fetch!(spec, :default))])

      true ->
        optional_decode(spec, term_arg, inner_option_type(Keyword.fetch!(spec, :type)))
    end
  end

  defp required_expr(spec, term_arg, :nif) do
    spec
    |> map_get(term_arg)
    |> A.try()
    |> A.method(:decode, [], generics: [Keyword.fetch!(spec, :type)])
    |> A.try()
  end

  defp required_expr(spec, term_arg, _result) do
    field = Keyword.fetch!(spec, :field)
    missing = Keyword.get(spec, :missing, "Missing :#{field}")
    invalid = Keyword.get(spec, :invalid, "Invalid :#{field}")

    spec
    |> map_get(term_arg)
    |> A.method(:map_err, [error_string_closure(missing)])
    |> A.try()
    |> A.method(:decode, [], generics: [Keyword.fetch!(spec, :type)])
    |> A.method(:map_err, [error_string_closure(invalid)])
    |> A.try()
  end

  defp optional_decode(spec, term_arg, type) do
    decoded =
      :term
      |> A.method(:decode, [], generics: [type])
      |> A.method(:ok)

    spec
    |> map_get(term_arg)
    |> A.method(:ok)
    |> A.method(:and_then, [A.closure([:term], decoded)])
  end

  defp map_get(spec, term_arg),
    do: A.method(ident_atom(term_arg), :map_get, [source_expr(Keyword.fetch!(spec, :key))])

  defp error_string_closure(message),
    do: A.closure([:_], A.method(A.lit(message), :to_string))

  defp source_expr(source) when is_binary(source), do: A.escape_expr(source)
  defp source_expr(expression), do: A.expr(expression)

  defp inner_option_type({:option, type}), do: type
  defp inner_option_type(type), do: type

  defp result_type(name, lifetime, :nif), do: {:raw, "NifResult<#{name}<'#{lifetime}>>"}
  defp result_type(name, lifetime, result), do: {:raw, "#{result}<#{name}<'#{lifetime}>>"}

  defp ident_atom(value) when is_atom(value), do: value
  defp ident_atom(value) when is_binary(value), do: Identifier.atom!(value)

  defp default_decoder_name(name), do: "decode_#{Macro.underscore(to_string(name))}"
end
