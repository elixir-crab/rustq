defmodule RustQ.Native.ABI do
  @moduledoc false
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.TypeBuilder, as: T
  alias RustQ.Rust.AST.Walk
  alias RustQ.Rust.Identifier

  def native_items(values) do
    result_targets =
      Map.new(
        for %AST.Function{returns: %AST.TypeResult{}, name: name, attrs: attrs} <- values[:items],
            Enum.any?(attrs, &match?(%AST.Attribute{path: [:rustler, :nif]}, &1)),
            do: {name, result_implementation_name(name)}
      )

    validate_result_names!(values[:items], result_targets)
    source_items = redirect_result_calls(values[:items], result_targets)

    map_structs =
      values[:type_aliases]
      |> Enum.flat_map(fn
        {_key, %Type{kind: :struct, meta: %{representation: :map} = meta}} ->
          [to_string(meta.rust_name)]

        _type ->
          []
      end)
      |> MapSet.new()

    resource_structs =
      values[:type_aliases]
      |> Enum.flat_map(fn
        {_key, %Type{kind: :resource} = type} ->
          case Type.inner(type) do
            %Type{rust: rust_name} -> [to_string(rust_name)]
            _type -> []
          end

        _type ->
          []
      end)
      |> MapSet.new()

    nif_structs =
      values[:type_aliases]
      |> Enum.flat_map(fn
        {_key,
         %Type{
           kind: :struct,
           meta: %{representation: :struct, rust_name: name, elixir_module: module}
         }} ->
          [{to_string(name), module}]

        _type ->
          []
      end)
      |> Map.new()

    unit_enums =
      values[:type_aliases]
      |> Enum.flat_map(fn
        {_key, %Type{kind: :enum} = type} ->
          [{to_string(type.rust), "decode_#{type.meta.elixir_name}_atom"}]

        _type ->
          []
      end)
      |> Map.new()

    tuple_enums =
      values[:type_aliases]
      |> Enum.flat_map(fn
        {_key, %Type{kind: :tuple_enum} = type} -> [{to_string(type.rust), type}]
        _type -> []
      end)
      |> Map.new()

    generated_decoders =
      map_structs
      |> MapSet.union(MapSet.new(Map.keys(nif_structs)))
      |> MapSet.new(fn name -> "decode_#{Macro.underscore(name)}" end)
      |> MapSet.union(MapSet.new(Map.values(unit_enums)))
      |> MapSet.union(
        MapSet.new(tuple_enums, fn {_name, type} -> "decode_#{type.meta.elixir_name}" end)
      )

    items =
      Enum.flat_map(source_items, fn
        %AST.Struct{name: name} = struct ->
          name = to_string(name)

          cond do
            MapSet.member?(resource_structs, name) ->
              [%{struct | derive: []}]

            MapSet.member?(map_structs, name) ->
              [%{struct | derive: Enum.uniq(struct.derive ++ ["rustler::NifMap"])}]

            module = Map.get(nif_structs, name) ->
              [derive_elixir_struct(struct, module)]

            true ->
              [struct]
          end

        %AST.Enum{name: name} = enum ->
          if Map.has_key?(unit_enums, to_string(name)) do
            [%{enum | derive: Enum.uniq(enum.derive ++ ["rustler::NifUnitEnum"])}]
          else
            [enum]
          end

        %AST.Function{} = function ->
          prepare_native_function(function, generated_decoders)

        item ->
          [item]
      end)

    resource_impls =
      resource_structs
      |> Enum.sort()
      |> Enum.map(fn name ->
        A.impl(T.path(name), trait: [:rustler, :Resource], attrs: [A.resource_impl_attr()])
      end)

    union_codecs =
      tuple_enums
      |> Enum.sort_by(fn {name, _type} -> name end)
      |> Enum.flat_map(fn {_name, type} -> union_codec_items(type) end)

    items ++ union_codecs ++ resource_impls
  end

  defp prepare_native_function(%AST.Function{name: name} = function, generated_decoders) do
    if MapSet.member?(generated_decoders, to_string(name)) do
      []
    else
      function |> expand_nif_result_codec() |> Enum.map(&prepare_expanded_native_item/1)
    end
  end

  defp prepare_expanded_native_item(%AST.Function{} = function) do
    add_generated_clippy_allows(function)
  end

  defp prepare_expanded_native_item(item) do
    item
  end

  defp derive_elixir_struct(%AST.Struct{} = struct, module) do
    derive =
      if function_exported?(module, :exception, 1) do
        "rustler::NifException"
      else
        "rustler::NifStruct"
      end

    %{
      struct
      | derive: Enum.uniq(struct.derive ++ [derive]),
        attrs: Enum.uniq(struct.attrs ++ [A.attr_value(:module, module_name(module))])
    }
  end

  defp validate_result_names!(items, targets) do
    declared =
      MapSet.new(for %{name: name} <- items, do: to_string(name))

    generated =
      Enum.flat_map(targets, fn {name, implementation} ->
        [to_string(implementation), Macro.camelize(to_string(name)) <> "NifResult"]
      end)

    Enum.reduce(generated, declared, fn name, names ->
      if MapSet.member?(names, name) do
        raise ArgumentError,
              "generated NIF result name #{inspect(name)} conflicts with another declaration"
      end

      MapSet.put(names, name)
    end)
  end

  defp result_implementation_name(name), do: Identifier.atom!("#{name}_rustq_result_impl")

  defp redirect_result_calls(items, targets) do
    Enum.map(items, fn
      %AST.Function{} = function ->
        %{function | body: redirect_result_body(function.body, targets)}

      item ->
        item
    end)
  end

  defp redirect_result_body(body, targets) do
    Walk.prewalk(body, fn
      %AST.LocalCall{name: name} = call ->
        %{call | name: Map.get(targets, name, name)}

      %AST.PathCall{path: %AST.Path{parts: [name]} = path} = call ->
        %{call | path: %{path | parts: [Map.get(targets, name, name)]}}

      %AST.Path{parts: [name]} = path ->
        %{path | parts: [Map.get(targets, name, name)]}

      node ->
        node
    end)
  end

  defp expand_nif_result_codec(
         %AST.Function{
           name: name,
           returns: %AST.TypeResult{ok: ok_type, error: error_type},
           attrs: attrs
         } = function
       ) do
    if Enum.any?(attrs, &match?(%AST.Attribute{path: [:rustler, :nif]}, &1)) do
      codec_name =
        name |> to_string() |> Macro.camelize() |> Kernel.<>("NifResult") |> Identifier.atom!()

      codec_path = [codec_name]

      codec = %AST.Enum{
        name: codec_name,
        vis: :pub,
        derive: ["Clone", "Debug", "rustler::NifTaggedEnum"],
        attrs: Enum.filter(attrs, &match?(%AST.Attribute{path: [:cfg]}, &1)),
        variants: [
          %AST.EnumVariant{name: :Ok, tuple: [ok_type]},
          %AST.EnumVariant{name: :Error, tuple: [error_type]}
        ]
      }

      implementation_name = result_implementation_name(name)

      implementation = %{
        function
        | name: implementation_name,
          attrs: Enum.reject(attrs, &match?(%AST.Attribute{path: [:rustler, :nif]}, &1))
      }

      arguments = Enum.map(function.args, fn %AST.FunctionArg{name: name} -> A.expr(name) end)

      body = [
        A.return_stmt(%AST.Match{
          expr: A.call(implementation_name, arguments),
          arms: [
            %AST.Arm{
              pattern: P.ok(:value),
              body: [A.return_stmt(A.path_call(codec_path ++ [:Ok], [:value]))]
            },
            %AST.Arm{
              pattern: P.err(:reason),
              body: [A.return_stmt(A.path_call(codec_path ++ [:Error], [:reason]))]
            }
          ]
        })
      ]

      [codec, implementation, %{function | returns: T.path(codec_path), body: body}]
    else
      [function]
    end
  end

  defp expand_nif_result_codec(%AST.Function{} = function) do
    [function]
  end

  defp union_codec_items(%Type{
         ast: %AST.TypePath{parts: enum_parts} = enum_type,
         meta: %{variants: variants}
       }) do
    decoder_arms =
      Enum.map(variants, fn {variant, [%Type{ast: payload_type}]} ->
        A.if_let(
          P.ok(:value),
          A.method(:term, :decode, [], generics: [payload_type]),
          [A.early_return(A.ok(A.path_call(enum_parts ++ [variant], [:value])))]
        )
      end)

    decoder = %AST.Function{
      name: :decode,
      args: A.function_args(term: T.term(:a)),
      returns: T.nif_result(enum_type),
      body: decoder_arms ++ [A.return_stmt(A.err(A.path([:rustler, :Error, :BadArg])))]
    }

    encoder_arms =
      Enum.map(variants, fn {variant, [_payload_type]} ->
        %AST.Arm{
          pattern: P.path_tuple(enum_parts ++ [variant], [:value]),
          body: [A.return_stmt(A.method(:value, :encode, [:env]))]
        }
      end)

    encoder = %AST.Function{
      name: :encode,
      args: [A.receiver(), A.arg(:env, T.path(:Env, lifetimes: [:a]))],
      returns: T.term(:a),
      lifetimes: [:a],
      body: [A.return_stmt(%AST.Match{expr: A.expr(:self), arms: encoder_arms})]
    }

    [
      A.impl(enum_type,
        trait: T.path([:rustler, :Decoder], lifetimes: [:a]),
        lifetimes: [:a],
        items: [decoder]
      ),
      A.impl(enum_type, trait: [:rustler, :Encoder], items: [encoder])
    ]
  end

  defp add_generated_clippy_allows(%AST.Function{} = function) do
    lints =
      function.body
      |> Walk.reduce(MapSet.new(), &generated_clippy_lints/2)
      |> add_unused_variables_lint(function)

    if MapSet.size(lints) == 0 do
      function
    else
      allow = A.attr(:allow, lints |> Enum.sort() |> Enum.map(&A.path/1))
      %{function | attrs: Enum.uniq(function.attrs ++ [allow])}
    end
  end

  defp add_unused_variables_lint(lints, %AST.Function{args: args, body: body}) do
    used =
      Walk.reduce(body, MapSet.new(), fn
        %AST.Var{name: name}, names -> MapSet.put(names, name)
        _node, names -> names
      end)

    if Enum.any?(args, fn
         %AST.FunctionArg{receiver: false, name: name} -> not MapSet.member?(used, name)
         %AST.FunctionArg{receiver: true} -> false
       end) do
      MapSet.put(lints, [:unused_variables])
    else
      lints
    end
  end

  defp generated_clippy_lints(
         %AST.MethodCall{
           method: :take,
           receiver: %AST.PathCall{path: %AST.Path{parts: [:std, :iter, :repeat]}}
         },
         lints
       ) do
    MapSet.put(lints, [:clippy, :manual_repeat_n])
  end

  defp generated_clippy_lints(%AST.MethodCall{method: :filter_map}, lints) do
    MapSet.put(lints, [:clippy, :unnecessary_filter_map])
  end

  defp generated_clippy_lints(%AST.MethodCall{method: :find_map}, lints) do
    MapSet.put(lints, [:clippy, :unnecessary_find_map])
  end

  defp generated_clippy_lints(%AST.MethodCall{method: :count}, lints) do
    MapSet.put(lints, [:clippy, :iter_count])
  end

  defp generated_clippy_lints(%AST.MethodCall{method: :fold}, lints) do
    MapSet.put(lints, [:clippy, :unnecessary_fold])
  end

  defp generated_clippy_lints(%AST.Match{arms: arms}, lints) do
    lints = add_single_match_lint(arms, lints)

    if option_match?(arms) do
      MapSet.put(lints, [:clippy, :manual_map])
    else
      lints
    end
  end

  defp generated_clippy_lints(%AST.StructLiteral{fields: fields}, lints) do
    if redundant_field_names?(fields) do
      MapSet.put(lints, [:clippy, :redundant_field_names])
    else
      lints
    end
  end

  defp generated_clippy_lints(%AST.PatStruct{}, lints) do
    MapSet.put(lints, [:non_shorthand_field_patterns])
  end

  defp generated_clippy_lints(_node, lints) do
    lints
  end

  defp add_single_match_lint([_single], lints) do
    MapSet.put(lints, [:clippy, :match_single_binding])
  end

  defp add_single_match_lint(_arms, lints) do
    lints
  end

  defp option_match?(arms) do
    Enum.any?(arms, &match?(%AST.Arm{pattern: %AST.PatNone{}}, &1)) and
      Enum.any?(arms, &match?(%AST.Arm{pattern: %AST.PatSome{}}, &1))
  end

  defp redundant_field_names?(fields) do
    Enum.any?(fields, fn
      {name, %AST.Var{name: name}} -> true
      _field -> false
    end)
  end

  defp module_name(module) do
    module |> Module.split() |> Enum.join(".")
  end
end
