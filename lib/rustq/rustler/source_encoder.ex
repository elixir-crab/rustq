defmodule RustQ.Rustler.SourceEncoder do
  @moduledoc false

  # Builds `Term` encoder functions for Rust structs and enums read from source
  # through `RustQ.Syn`. See `RustQ.Rustler.Term.encoders_from_source/3`.

  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.TypeBuilder
  alias RustQ.Rust.Identifier
  alias RustQ.Syn
  alias RustQ.Syn.Index
  alias RustQ.Syn.Type

  require A

  @scalars ~w(bool u8 u16 u32 u64 u128 usize i8 i16 i32 i64 i128 isize f32 f64 str)

  @default_wrappers [
    pointer: ~w(Box Rc Arc),
    sequence: ~w(Vec VecDeque),
    set: ~w(HashSet BTreeSet),
    map: ~w(HashMap BTreeMap),
    string: ~w(String)
  ]

  @wrapper_roles Keyword.keys(@default_wrappers)

  defmodule Plan do
    @moduledoc false
    defstruct [:config, types: %{}, order: [], atoms: MapSet.new()]
  end

  @spec functions(Index.t() | [Path.t()], [atom() | String.t()], keyword()) :: [AST.Function.t()]
  def functions(source, roots, opts) do
    plan = plan!(source, roots, opts)
    Enum.map(plan.order, &function(plan, Map.fetch!(plan.types, &1)))
  end

  @spec atoms(Index.t() | [Path.t()], [atom() | String.t()], keyword()) ::
          [String.t() | {atom(), String.t()}]
  def atoms(source, roots, opts) do
    plan = plan!(source, roots, opts)

    plan.types
    |> Map.values()
    |> Enum.flat_map(&item_atoms(plan, &1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&atom_declaration/1)
  end

  ## Planning

  defp plan!(source, roots, opts) do
    config = config(opts)
    index = index(source)
    items = index |> named_items() |> Enum.group_by(& &1.name)

    {types, order, errors} =
      roots
      |> Enum.map(&to_string/1)
      |> Enum.map(&{&1, :root})
      |> resolve(items, config, %{}, [], [])

    plan = %Plan{config: config, types: types, order: Enum.reverse(order)}
    errors = if errors == [], do: transparency_errors(plan) ++ tag_collisions(plan), else: errors

    if errors != [] do
      raise ArgumentError, error_message(errors)
    end

    plan
  end

  defp transparency_errors(plan) do
    for name <- plan.order,
        item = Map.fetch!(plan.types, name),
        match?(%Syn.Struct{}, item),
        transparent?(plan, item),
        (count = length(item_fields(item, plan.config))) != 1,
        do: {:transparent, item.name, count}
  end

  # A tag must not replace a payload field with the same key.
  defp tag_collisions(plan) do
    for name <- plan.order,
        item = Map.fetch!(plan.types, name),
        match?(%Syn.Enum{}, item),
        tag = tag(plan, item),
        tag != nil,
        variant <- item.variant_shapes,
        tag in payload_keys(plan, item, variant),
        do: {:tag_collision, item.name, variant.name, tag}
  end

  defp payload_keys(plan, item, %Syn.Variant{kind: :named} = variant),
    do: item.name |> selected_fields(variant.fields, plan.config) |> field_keys()

  defp payload_keys(plan, item, %Syn.Variant{kind: :tuple} = variant) do
    case selected_fields(item.name, variant.fields, plan.config) do
      [{_index, type, opts}] -> payload_shape_keys(plan, field_shape(type, opts, plan.config))
      _fields -> []
    end
  end

  defp payload_keys(_plan, _item, _variant), do: []

  defp payload_shape_keys(plan, {wrapper, inner}) when wrapper in [:pointer, :ref],
    do: payload_shape_keys(plan, inner)

  defp payload_shape_keys(plan, {:type, name} = shape) do
    if map_shape?(plan, shape),
      do: plan |> item_atoms(Map.fetch!(plan.types, name)),
      else: []
  end

  defp payload_shape_keys(_plan, _shape), do: []

  defp index(%Index{} = index), do: index
  defp index(paths) when is_list(paths), do: Index.from_paths(paths)

  defp named_items(index), do: Index.structs(index) ++ Index.enums(index)

  defp config(opts) do
    wrappers =
      Enum.reduce(@wrapper_roles, %{}, fn role, acc ->
        names = Keyword.fetch!(@default_wrappers, role) ++ names(opts, [:wrappers, role])
        Enum.reduce(names, acc, &Map.put(&2, &1, role))
      end)

    %{
      tag: Keyword.get(opts, :tag),
      vis: Keyword.get(opts, :vis, :crate),
      wrappers: wrappers,
      external:
        opts
        |> Keyword.get(:external, [])
        |> Map.new(fn {name, helper} -> {to_string(name), List.wrap(helper)} end),
      types:
        opts
        |> Keyword.get(:types, [])
        |> Map.new(fn {name, type_opts} -> {to_string(name), type_opts} end)
    }
  end

  defp names(opts, path) do
    opts |> get_in(path) |> List.wrap() |> Enum.map(&to_string/1)
  end

  defp resolve([], _items, _config, types, order, errors), do: {types, order, errors}

  defp resolve([{name, from} | rest], items, config, types, order, errors) do
    if Map.has_key?(types, name) do
      resolve(rest, items, config, types, order, errors)
    else
      {pending, {types, order, errors}} =
        resolve_name(name, from, Map.get(items, name, []), config, {types, order, errors})

      resolve(rest ++ pending, items, config, types, order, errors)
    end
  end

  defp resolve_name(name, from, [], _config, {types, order, errors}),
    do: {[], {types, order, errors ++ [{:unmapped, name, from}]}}

  defp resolve_name(name, _from, [item], config, {types, order, errors}) do
    case unsupported_generics(item) do
      nil ->
        {pending, field_errors} =
          item
          |> item_fields(config)
          |> Enum.flat_map(&referenced(&1, config))
          |> split_references(item.name)

        {pending, {Map.put(types, name, item), [name | order], errors ++ field_errors}}

      error ->
        {[], {types, order, errors ++ [error]}}
    end
  end

  defp resolve_name(name, _from, candidates, _config, {types, order, errors}) do
    error = {:ambiguous, name, Enum.map(candidates, & &1.source_path)}
    {[], {types, order, errors ++ [error]}}
  end

  defp unsupported_generics(%{type_parameters: []}), do: nil

  defp unsupported_generics(%{name: name, type_parameters: params}),
    do: {:generic, name, params}

  defp split_references(referenced, owner) do
    {types, unsupported} = Enum.split_with(referenced, &match?({:type, _name}, &1))

    {Enum.map(types, fn {:type, name} -> {name, owner} end),
     Enum.map(unsupported, fn {:unsupported, code} -> {:unsupported, code, owner} end)}
  end

  # A field as {key, rust_name, type_ast, field_opts}, after `except:` and renames.
  defp item_fields(%Syn.Struct{fields: fields} = item, config),
    do: selected_fields(item.name, fields, config)

  defp item_fields(%Syn.Enum{variant_shapes: variants} = item, config),
    do: Enum.flat_map(variants, &selected_fields(item.name, &1.fields, config))

  defp selected_fields(owner, fields, config) do
    type_opts = Map.get(config.types, owner, [])
    except = type_opts |> Keyword.get(:except, []) |> Enum.map(&to_string/1)

    field_opts =
      type_opts |> Keyword.get(:fields, []) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    fields
    |> Enum.with_index()
    |> Enum.reject(fn {field, _index} -> field.name && field_name(field) in except end)
    |> Enum.map(fn {field, index} ->
      name = if field.name, do: field_name(field), else: index
      {name, field.type_ast, Map.get(field_opts, to_string(name), [])}
    end)
  end

  defp field_name(%Syn.Field{name: "r#" <> name}), do: name
  defp field_name(%Syn.Field{name: name}), do: name

  defp referenced({_name, type, opts}, config),
    do: type |> field_shape(opts, config) |> shape_types()

  defp shape_types({:type, name}), do: [{:type, name}]
  defp shape_types({:unsupported, code}), do: [{:unsupported, code}]
  defp shape_types({_wrapper, inner}) when is_tuple(inner), do: shape_types(inner)
  defp shape_types({:map, key, value}), do: Enum.flat_map([key, value], &shape_types/1)
  defp shape_types(_leaf), do: []

  ## Shapes

  # Classifies a Syn type into the encoding it needs.
  defp shape(%Type.Option{inner: inner}, config), do: {:option, shape(inner, config)}
  defp shape(%Type.Ref{inner: inner}, config), do: {:ref, shape(inner, config)}
  defp shape(%Type.Slice{inner: inner}, config), do: {:sequence, shape(inner, config)}
  defp shape(%Type.Array{inner: inner}, config), do: {:sequence, shape(inner, config)}

  defp shape(%Type.Path{name: name} = path, config) do
    cond do
      helper = Map.get(config.external, name) -> {:external, helper}
      name in @scalars -> :scalar
      true -> wrapper_shape(Map.get(config.wrappers, name), path, config)
    end
  end

  defp shape(%{code: code}, _config), do: {:unsupported, code}

  defp wrapper_shape(:string, _path, _config), do: :string
  defp wrapper_shape(nil, %Type.Path{name: name}, _config), do: {:type, name}

  defp wrapper_shape(:map, path, config) do
    case type_args(path) do
      [key, value | _] -> {:map, shape(key, config), shape(value, config)}
      _other -> {:unsupported, path.code}
    end
  end

  defp wrapper_shape(role, path, config) do
    case type_args(path) do
      [inner | _] -> {wrapper_role(role), shape(inner, config)}
      [] -> {:unsupported, path.code}
    end
  end

  defp wrapper_role(:set), do: :sequence
  defp wrapper_role(role), do: role

  defp type_args(%Type.Path{generic_args: args}) do
    for %Type.GenericArgument{kind: :type, type: type} <- args || [], do: type
  end

  ## Generation

  defp function(plan, item) do
    %AST.Function{
      name: function_name(item.name),
      vis: plan.config.vis,
      lifetimes: [:a],
      args: [
        A.arg(:env, A.type_path([:rustler, :Env], lifetimes: [:a])),
        A.arg(:value, A.type(ref_type(item)))
      ],
      returns: A.type_path([:rustler, :Term], lifetimes: [:a]),
      body: [A.return(body(plan, item))]
    }
  end

  defp ref_type(item) do
    lifetimes = Enum.map(item.lifetimes, fn _ -> :_ end)
    TypeBuilder.ref(A.type_path(Identifier.atom!(item.name), lifetimes: lifetimes))
  end

  defp body(plan, %Syn.Struct{} = item) do
    case transparent_field(plan, item) do
      {:ok, {name, type, opts}} ->
        encode(A.ref(A.field(:value, field_ident(name))), field_shape(type, opts, plan.config), 0)

      :error ->
        map(Enum.map(item_fields(item, plan.config), &struct_entry(plan, &1)))
    end
  end

  defp body(plan, %Syn.Enum{} = item) do
    A.match_expr(:value, Enum.map(item.variant_shapes, &variant_arm(plan, item, &1)))
  end

  # A newtype, or a struct marked `transparent: true`, encodes as its only field.
  defp transparent_field(plan, %Syn.Struct{} = item) do
    case {item_fields(item, plan.config), transparent?(plan, item)} do
      {[{0, _type, _opts} = field], _transparent} -> {:ok, field}
      {[field], true} -> {:ok, field}
      _other -> :error
    end
  end

  defp transparent?(plan, item),
    do: plan.config.types |> Map.get(item.name, []) |> Keyword.get(:transparent, false)

  defp struct_entry(plan, {name, type, opts}) do
    {key(name, opts),
     encode(A.ref(A.field(:value, field_ident(name))), field_shape(type, opts, plan.config), 0)}
  end

  defp field_shape(type, opts, config) do
    case Keyword.fetch(opts, :with) do
      {:ok, helper} -> {:external, List.wrap(helper)}
      :error -> shape(type, config)
    end
  end

  defp variant_arm(plan, item, %Syn.Variant{} = variant) do
    path = [Identifier.atom!(item.name), Identifier.atom!(variant.name)]
    tag = tag(plan, item)
    variant_atom = variant_atom(plan, item, variant)
    fields = selected_fields(item.name, variant.fields, plan.config)

    case variant.kind do
      :unit ->
        %AST.Arm{pattern: P.path(path), body: [A.return(unit_value(tag, variant_atom))]}

      :named ->
        entries = Enum.map(fields, &named_entry(plan, &1))
        tagged = if tag, do: [{tag, atom_term(variant_atom)} | entries], else: entries

        %AST.Arm{
          pattern:
            P.struct(
              path,
              Enum.map(fields, fn {name, _, _} ->
                {field_ident(name), P.var(pattern_var(name))}
              end)
            ),
          body: [A.return(map(tagged))]
        }

      :tuple ->
        bindings = Enum.map(fields, fn {index, _, _} -> pattern_var(index) end)

        %AST.Arm{
          pattern: P.path_tuple(path, bindings),
          body: [A.return(tuple_value(plan, tag, variant_atom, fields))]
        }
    end
  end

  defp named_entry(plan, {name, type, opts}) do
    {key(name, opts), encode(A.var(pattern_var(name)), field_shape(type, opts, plan.config), 0)}
  end

  defp tuple_value(plan, nil, _variant_atom, [{index, type, opts}]),
    do: encode(A.var(pattern_var(index)), field_shape(type, opts, plan.config), 0)

  defp tuple_value(plan, tag, variant_atom, [{index, type, opts}]) do
    shape = field_shape(type, opts, plan.config)
    payload = encode(A.var(pattern_var(index)), shape, 0)

    if map_shape?(plan, shape) do
      payload
      |> A.method(:map_put, [atom_term(tag), atom_term(variant_atom)])
      |> A.method(:unwrap)
    else
      map([{tag, atom_term(variant_atom)}, {:value, payload}])
    end
  end

  defp tuple_value(plan, tag, variant_atom, fields) do
    elements =
      Enum.map(fields, fn {index, type, opts} ->
        encode(A.var(pattern_var(index)), field_shape(type, opts, plan.config), 0)
      end)

    tuple = A.path_call([:rustler, :types, :tuple, :make_tuple], [:env, A.ref(A.array(elements))])

    if tag, do: map([{tag, atom_term(variant_atom)}, {:value, tuple}]), else: tuple
  end

  defp unit_value(nil, variant_atom), do: atom_term(variant_atom)
  defp unit_value(tag, variant_atom), do: map([{tag, atom_term(variant_atom)}])

  # A tuple payload merges the tag into its map when it encodes as a map.
  defp map_shape?(plan, {:pointer, inner}), do: map_shape?(plan, inner)
  defp map_shape?(plan, {:ref, inner}), do: map_shape?(plan, inner)

  defp map_shape?(plan, {:type, name}) do
    case Map.fetch!(plan.types, name) do
      %Syn.Struct{} = item -> struct_map_shape?(plan, item)
      %Syn.Enum{} -> false
    end
  end

  defp map_shape?(_plan, _shape), do: false

  defp struct_map_shape?(plan, item) do
    case transparent_field(plan, item) do
      {:ok, {_name, type, opts}} -> map_shape?(plan, field_shape(type, opts, plan.config))
      :error -> true
    end
  end

  # `value` is an expression that evaluates to a reference to the encoded value.
  defp encode(value, :scalar, _depth), do: A.method(receiver(value), :encode, [:env])

  defp encode(value, :string, _depth),
    do: value |> receiver() |> A.method(:as_str) |> A.method(:encode, [:env])

  defp encode(value, {:external, helper}, _depth), do: A.path_call(helper, [:env, value])
  defp encode(value, {:type, name}, _depth), do: A.call(function_name(name), [:env, value])
  defp encode(value, {:ref, inner}, depth), do: encode(deref(value), inner, depth)

  # Functions taking `&T` accept `&Box<T>` through deref coercion; method
  # receivers need the explicit dereference.
  defp encode(value, {:pointer, inner}, depth) do
    if coerces?(inner),
      do: encode(value, inner, depth),
      else: encode(A.ref(A.deref(deref(value))), inner, depth)
  end

  defp encode(value, {:option, inner}, depth) do
    item = item_var(depth)

    value
    |> receiver()
    |> A.method(:as_ref)
    |> A.method(:map, [A.closure([item], encode(A.var(item), inner, depth + 1))])
    |> A.method(:unwrap_or_else, [A.closure([], nil_term())])
  end

  defp encode(value, {:sequence, inner}, depth) do
    item = item_var(depth)

    value
    |> receiver()
    |> A.method(:iter)
    |> A.method(:map, [A.closure([item], encode(A.var(item), inner, depth + 1))])
    |> A.method(:collect, [], generics: [A.type_path(:Vec, generics: [term_type()])])
    |> A.method(:encode, [:env])
  end

  defp encode(value, {:map, key, entry}, depth) do
    key_var = Identifier.atom!("key#{depth}")
    entry_var = item_var(depth)

    pairs =
      value
      |> receiver()
      |> A.method(:iter)
      |> A.method(:map, [
        A.closure(
          [P.tuple([key_var, entry_var])],
          A.tuple([
            encode(A.var(key_var), key, depth + 1),
            encode(A.var(entry_var), entry, depth + 1)
          ])
        )
      ])
      |> A.method(:collect, [],
        generics: [A.type_path(:Vec, generics: [TypeBuilder.tuple([term_type(), term_type()])])]
      )

    [:rustler, :Term, :map_from_pairs]
    |> A.path_call([:env, A.ref(pairs)])
    |> A.method(:unwrap)
  end

  defp coerces?({:type, _name}), do: true
  defp coerces?({:external, _helper}), do: true
  defp coerces?({:pointer, inner}), do: coerces?(inner)
  defp coerces?(_shape), do: false

  # A method call borrows its receiver itself.
  defp receiver(%AST.Ref{expr: expr, mutable: false}), do: expr
  defp receiver(expr), do: expr

  defp deref(%AST.Ref{expr: expr, mutable: false}), do: expr
  defp deref(expr), do: A.deref(expr)

  defp map([]), do: A.path_call([:rustler, :Term, :map_new], [:env])

  defp map(entries) do
    {keys, values} = Enum.unzip(entries)

    [:rustler, :Term, :map_from_arrays]
    |> A.path_call([:env, A.ref(A.array(Enum.map(keys, &atom_term/1))), A.ref(A.array(values))])
    |> A.method(:unwrap)
  end

  defp atom_term(name), do: A.method(A.path_call([:atoms, name]), :encode, [:env])

  defp nil_term,
    do: A.method(A.path_call([:rustler, :types, :atom, nil], []), :encode, [:env])

  defp term_type, do: A.type_path([:rustler, :Term], lifetimes: [:a])

  defp item_var(depth), do: Identifier.atom!("item#{depth}")

  ## Naming policy

  defp function_name(type_name), do: Identifier.atom!("encode_" <> Macro.underscore(type_name))

  defp field_ident(index) when is_integer(index), do: index
  defp field_ident(name), do: Identifier.atom!(name)

  defp pattern_var(index) when is_integer(index), do: Identifier.atom!("field#{index}")
  defp pattern_var(name), do: Identifier.atom!(name)

  defp key(name, opts), do: opts |> Keyword.get(:key, name) |> to_string() |> Identifier.atom!()

  defp tag(plan, item) do
    type_opts = Map.get(plan.config.types, item.name, [])

    case Keyword.get(type_opts, :tag, plan.config.tag) do
      false -> nil
      nil -> nil
      tag -> if all_unit?(item), do: nil, else: Identifier.atom!(to_string(tag))
    end
  end

  defp all_unit?(%Syn.Enum{variant_shapes: variants}),
    do: Enum.all?(variants, &(&1.kind == :unit))

  defp variant_atom(plan, item, variant) do
    renames = plan.config.types |> Map.get(item.name, []) |> Keyword.get(:variants, [])

    renames
    |> Enum.find_value(fn {name, atom} -> if to_string(name) == variant.name, do: atom end)
    |> Kernel.||(Macro.underscore(variant.name))
    |> to_string()
    |> Identifier.atom!()
  end

  ## Atoms

  defp item_atoms(plan, %Syn.Struct{} = item) do
    case transparent_field(plan, item) do
      {:ok, _field} -> []
      :error -> item |> item_fields(plan.config) |> field_keys()
    end
  end

  defp item_atoms(plan, %Syn.Enum{} = item) do
    tag = tag(plan, item)
    Enum.flat_map(item.variant_shapes, &variant_atoms(plan, item, tag, &1))
  end

  defp variant_atoms(plan, item, tag, variant) do
    fields = selected_fields(item.name, variant.fields, plan.config)
    [variant_atom(plan, item, variant) | variant_keys(plan, tag, variant.kind, fields)]
  end

  defp variant_keys(_plan, nil, :named, fields), do: field_keys(fields)
  defp variant_keys(_plan, tag, :named, fields), do: [tag | field_keys(fields)]
  defp variant_keys(_plan, nil, _kind, _fields), do: []
  defp variant_keys(_plan, tag, :unit, _fields), do: [tag]

  defp variant_keys(plan, tag, :tuple, fields) do
    if single_map_payload?(plan, fields), do: [tag], else: [tag, :value]
  end

  defp field_keys(fields), do: Enum.map(fields, fn {name, _type, opts} -> key(name, opts) end)

  defp single_map_payload?(plan, [{_index, type, opts}]),
    do: map_shape?(plan, field_shape(type, opts, plan.config))

  defp single_map_payload?(_plan, _fields), do: false

  @rust_keywords ~w(as async await break const continue crate dyn else enum extern false fn for if impl
                    in let loop match mod move mut pub ref return self Self static struct super trait true
                    type unsafe use where while)

  defp atom_declaration(atom) do
    name = Atom.to_string(atom)
    if name in @rust_keywords, do: {atom, name}, else: name
  end

  ## Errors

  defp error_message(errors) do
    lines =
      errors
      |> group_owners()
      |> Enum.map(fn
        {:unmapped, name, :root} ->
          "  root type #{name} is not in the index"

        {:unmapped, name, owners} ->
          "  #{name} (used by #{Enum.join(owners, ", ")}) is not in the index; add it to :external or :wrappers, or exclude the field"

        {:transparent, name, count} ->
          "  #{name} is transparent but has #{count} fields; it needs exactly one"

        {:ambiguous, name, paths} ->
          "  #{name} is defined in several sources: #{Enum.join(paths, ", ")}"

        {:generic, name, params} ->
          "  #{name} has type parameters (#{Enum.join(params, ", ")}), which are not supported; map it in :external"

        {:tag_collision, enum, variant, tag} ->
          "  #{enum}::#{variant} already has a #{tag} field; rename it with :fields or choose another :tag"

        {:unsupported, code, owners} ->
          "  #{code} (used by #{Enum.join(owners, ", ")}) has no encoding; map it in :external or exclude the field"
      end)

    Enum.join(["cannot build Term encoders from source:" | Enum.uniq(lines)], "\n")
  end

  # Reports each unmapped or unsupported type once, with every type that uses it.
  defp group_owners(errors) do
    {grouped, others} =
      Enum.split_with(errors, fn error ->
        match?({:unmapped, _name, owner} when owner != :root, error) or
          match?({:unsupported, _code, _owner}, error)
      end)

    owners =
      grouped
      |> Enum.group_by(fn {kind, name, _owner} -> {kind, name} end, &elem(&1, 2))
      |> Enum.map(fn {{kind, name}, owners} ->
        {kind, name, owners |> Enum.uniq() |> Enum.sort()}
      end)
      |> Enum.sort()

    others ++ owners
  end
end
