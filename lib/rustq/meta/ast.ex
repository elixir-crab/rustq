defmodule RustQ.Meta.AST do
  @moduledoc """
  Builds RustQ AST items from `defrust` metadata and explicit quoted bodies.
  """

  alias RustQ.Binding.Callable
  alias RustQ.Diagnostic
  alias RustQ.Meta.Decoder
  alias RustQ.Meta.Lower
  alias RustQ.Meta.RustMacro
  alias RustQ.Meta.Type
  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.Identifier

  require A

  @doc """
  Returns every generated Rust item from a compiled RustQ module.

  This is the public structural accessor for generated type declarations,
  functions, modules, and implementation blocks.
  """
  @spec items(module()) :: [AST.item()]
  def items(module) when is_atom(module), do: metadata!(module, :__rustq_items__, "Rust item")

  @doc "Returns every generated Rust type item from a compiled RustQ module."
  @spec generated_type_items(module()) :: [AST.item()]
  def generated_type_items(module) when is_atom(module),
    do: metadata!(module, :__rustq_type_items__, "Rust type item")

  @doc "Returns one generated Rust type item by name, raising when absent."
  @spec type_item!(module(), atom() | String.t()) :: AST.item()
  def type_item!(module, name) when is_atom(module) do
    name = Identifier.atom!(to_string(name))

    Enum.find(generated_type_items(module), &(Map.get(&1, :name) == name)) ||
      raise ArgumentError, "#{inspect(module)} has no generated Rust type item named #{name}"
  end

  @doc "Returns one generated Rust enum type item by name, raising on absence or kind mismatch."
  @spec enum_type_item!(module(), atom() | String.t()) :: AST.Enum.t()
  def enum_type_item!(module, name) do
    case type_item!(module, name) do
      %AST.Enum{} = item -> item
      item -> raise ArgumentError, "expected #{item_name(item)} to be a generated Rust enum"
    end
  end

  @doc "Returns one generated Rust struct type item by name, raising on absence or kind mismatch."
  @spec struct_type_item!(module(), atom() | String.t()) :: AST.Struct.t()
  def struct_type_item!(module, name) do
    case type_item!(module, name) do
      %AST.Struct{} = item -> item
      item -> raise ArgumentError, "expected #{item_name(item)} to be a generated Rust struct"
    end
  end

  @doc "Returns every generated Rust implementation block from a compiled module."
  @spec impls(module()) :: [AST.Impl.t()]
  def impls(module) when is_atom(module), do: Enum.filter(items(module), &match?(%AST.Impl{}, &1))

  @doc """
  Returns one generated Rust implementation block for a target.

  Pass `trait: Name` to select a trait implementation. Without `:trait`, only
  inherent implementations match. Raises when no implementation matches or
  when the selector is ambiguous.
  """
  @spec impl!(module(), atom() | String.t() | [atom() | String.t()], keyword()) :: AST.Impl.t()
  def impl!(module, target, opts \\ []) when is_atom(module) and is_list(opts) do
    trait = Keyword.get(opts, :trait)

    matches =
      Enum.filter(impls(module), fn impl ->
        type_path_matches?(impl.target, target) and trait_matches?(impl.trait, trait)
      end)

    case matches do
      [impl] ->
        impl

      [] ->
        trait_suffix = if trait, do: " for trait #{format_path(trait)}", else: ""

        raise ArgumentError,
              "#{inspect(module)} has no generated Rust impl for #{format_path(target)}#{trait_suffix}"

      _matches ->
        raise ArgumentError,
              "#{inspect(module)} has multiple generated Rust impls for #{format_path(target)}; refine the selector with :trait"
    end
  end

  @doc """
  Returns all generated `defrust` function AST nodes from a compiled module.

  Raises `ArgumentError` when the module does not contain compiled `defrust`
  metadata.
  """
  @spec functions(module()) :: [AST.Function.t()]
  def functions(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__rustq_asts__, 0) do
      module.__rustq_asts__()
    else
      raise ArgumentError, "#{inspect(module)} has no compiled defrust function metadata"
    end
  end

  @doc "Returns one generated `defrust` function AST by name, raising when absent."
  @spec function!(module(), atom() | String.t()) :: AST.Function.t()
  def function!(module, name) when is_atom(module) do
    name = Identifier.atom!(to_string(name))

    Enum.find(functions(module), &(&1.name == name)) ||
      raise ArgumentError, "#{inspect(module)} has no defrust function named #{name}"
  end

  @doc "Returns selected generated `defrust` function AST nodes."
  @spec functions!(module(), [atom() | String.t()]) :: [AST.Function.t()]
  def functions!(module, names) when is_atom(module) and is_list(names),
    do: Enum.map(names, &function!(module, &1))

  @doc """
  Builds Rust struct items for selected map-backed `@type` declarations.

  Use `:derive`, `:attrs`, and `:vis` to adapt the structural type item at a
  boundary such as Rustler encoding without duplicating its fields.
  """
  @spec struct_type_items(module(), [atom()], keyword()) :: [AST.Struct.t()]
  def struct_type_items(module, names, opts \\ []) do
    names = names |> Enum.map(&to_string/1) |> MapSet.new()

    module.__rustq_type_asts__()
    |> Enum.filter(fn
      %AST.Struct{name: name} ->
        MapSet.member?(names, name |> to_string() |> Macro.underscore())

      _item ->
        false
    end)
    |> Enum.map(fn struct ->
      fields =
        if Keyword.has_key?(opts, :field_vis) do
          Enum.map(struct.fields, &%{&1 | vis: Keyword.fetch!(opts, :field_vis)})
        else
          struct.fields
        end

      %{
        struct
        | derive: Keyword.get(opts, :derive, struct.derive),
          attrs: Keyword.get(opts, :attrs, struct.attrs),
          vis: Keyword.get(opts, :vis, struct.vis),
          fields: fields
      }
    end)
  end

  @doc "Returns one generated `defrustmacro` item AST by name, raising when absent."
  @spec macro_item!(module(), atom() | String.t()) :: AST.MacroItem.t()
  def macro_item!(module, name) when is_atom(module) do
    name = Identifier.atom!(to_string(name))

    module.__rustq_macro_items__()
    |> Enum.find(&(&1.name == name))
    |> case do
      %{ast: %AST.MacroItem{} = ast} -> ast
      nil -> raise ArgumentError, "#{inspect(module)} has no defrustmacro item named #{name}"
    end
  end

  @doc "Returns selected generated `defrustmacro` item AST nodes."
  @spec macro_items!(module(), [atom() | String.t()]) :: [AST.MacroItem.t()]
  def macro_items!(module, names) when is_atom(module) and is_list(names),
    do: Enum.map(names, &macro_item!(module, &1))

  @doc "Builds a structural invocation of a generated Rust item macro."
  @spec macro_call!(module(), atom() | String.t(), keyword()) :: AST.MacroItemCall.t()
  def macro_call!(module, name, args) when is_atom(module) and is_list(args) do
    module
    |> macro_definition!(name)
    |> RustMacro.item_call(args)
  end

  defp metadata!(module, function, description) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      raise ArgumentError, "#{inspect(module)} has no compiled #{description} metadata"
    end
  end

  defp type_path_matches?(%AST.TypePath{parts: parts}, expected),
    do: normalize_path(parts) == normalize_path(expected)

  defp type_path_matches?(_type, _expected), do: false

  defp trait_matches?(nil, nil), do: true

  defp trait_matches?(%AST.TypePath{} = actual, expected) when not is_nil(expected),
    do: type_path_matches?(actual, expected)

  defp trait_matches?(_actual, _expected), do: false

  defp normalize_path(parts) when is_list(parts), do: Enum.map(parts, &to_string/1)
  defp normalize_path(path) when is_atom(path), do: [to_string(path)]
  defp normalize_path(path) when is_binary(path), do: String.split(path, "::")

  defp format_path(path), do: path |> normalize_path() |> Enum.join("::")
  defp item_name(item), do: Map.get(item, :name, item.__struct__) |> to_string()

  defp macro_definition!(module, name) when is_atom(module) do
    name = Identifier.atom!(to_string(name))

    module.__rustq_macro_definitions__()
    |> Enum.find(&(&1.name == name))
    |> case do
      %RustMacro.Definition{} = definition -> definition
      nil -> raise ArgumentError, "#{inspect(module)} has no defrustmacro item named #{name}"
    end
  end

  @doc false
  @spec quoted(atom(), keyword()) :: AST.Function.t()
  def quoted(name, opts) do
    args = Keyword.fetch!(opts, :args)
    return_type = Keyword.fetch!(opts, :returns)
    body_ast = Keyword.fetch!(opts, :do)
    type_aliases = Keyword.get(opts, :type_aliases, %{})
    arg_names = Enum.map(args, &elem(&1, 0))
    arg_types = Enum.map(args, fn {_name, type} -> normalize_type(type, type_aliases) end)
    return_type = normalize_type(return_type, type_aliases)

    function_args =
      Enum.zip(arg_names, Enum.map(arg_types, & &1.ast))
      |> Enum.map(fn {name, type} -> %AST.FunctionArg{name: name, type: type} end)

    body =
      Lower.quoted_body(body_ast, return_type, Map.new(Enum.zip(arg_names, arg_types)),
        rust_modules: Keyword.get(opts, :rust_modules, %{})
      )

    lifetime =
      Keyword.get_lazy(opts, :lifetime, fn ->
        if Enum.any?(arg_types ++ [return_type], &Type.lifetime?/1), do: :a
      end)

    %AST.Function{
      name: name,
      args: function_args,
      returns: return_type.ast,
      body: body,
      lifetimes: List.wrap(lifetime),
      vis: Keyword.get(opts, :vis),
      attrs: Keyword.get(opts, :attrs, [])
    }
  end

  @doc false
  def build_ast(
        definition,
        specs,
        type_aliases,
        rust_modules,
        env,
        external_callables \\ [],
        external_static_types \\ %{},
        rust_macros \\ %{}
      )

  def build_ast(
        {call_ast, body_ast},
        specs,
        type_aliases,
        rust_modules,
        env,
        external_callables,
        external_static_types,
        rust_macros
      ),
      do:
        build_ast(
          {call_ast, body_ast, [], nil, nil},
          specs,
          type_aliases,
          rust_modules,
          env,
          external_callables,
          external_static_types,
          rust_macros
        )

  def build_ast(
        {call_ast, body_ast, attrs},
        specs,
        type_aliases,
        rust_modules,
        env,
        external_callables,
        external_static_types,
        rust_macros
      ),
      do:
        build_ast(
          {call_ast, body_ast, attrs, nil, nil},
          specs,
          type_aliases,
          rust_modules,
          env,
          external_callables,
          external_static_types,
          rust_macros
        )

  def build_ast(
        {call_ast, body_ast, attrs, rust_module, rust_impl},
        specs,
        type_aliases,
        rust_modules,
        env,
        external_callables,
        external_static_types,
        rust_macros
      ) do
    do_build_ast(
      {call_ast, body_ast, attrs, rust_module, rust_impl},
      specs,
      type_aliases,
      rust_modules,
      env,
      external_callables,
      external_static_types,
      rust_macros
    )
  rescue
    error in Diagnostic.Error ->
      raise_defrust_diagnostic(call_ast, body_ast, error.diagnostic)

    error in [ArgumentError, FunctionClauseError] ->
      raise_defrust_diagnostic(call_ast, body_ast, error)
  end

  @doc false
  def build_type_asts(type_aliases) do
    type_aliases
    |> Map.values()
    |> Enum.flat_map(&type_items/1)
  end

  @doc false
  def group_items(built_asts, rust_modules \\ %{}) do
    {plain, nested} = Enum.split_with(built_asts, &is_nil(&1.rust_module))

    plain_items = group_impl_asts(plain, rust_modules)

    nested_items =
      nested
      |> Enum.group_by(& &1.rust_module)
      |> Enum.map(fn {module, items} ->
        %AST.Module{name: List.last(module), items: group_impl_asts(items, rust_modules)}
      end)

    plain_items ++ nested_items
  end

  @doc false
  def group_module_asts(built_asts), do: group_items(built_asts)

  defp group_impl_asts(built_asts, rust_modules) do
    {methods, ordinary} =
      Enum.split_with(built_asts, &Map.get(&1, :rust_impl))

    ordinary_items = Enum.map(ordinary, & &1.ast)

    impl_items =
      methods
      |> Enum.group_by(& &1.rust_impl)
      |> Enum.map(fn {impl, entries} ->
        %AST.Impl{
          target: impl_type!(impl.target, rust_modules),
          trait: impl.trait && impl_type!(impl.trait, rust_modules),
          attrs: impl.attrs,
          lifetimes: impl.lifetimes,
          items: Enum.map(entries, &method_ast(&1.ast, impl.vis))
        }
      end)

    ordinary_items ++ impl_items
  end

  defp method_ast(%AST.Function{args: [receiver | args]} = function, vis) do
    unless match?(%AST.TypeRef{}, receiver.type) do
      raise ArgumentError,
            "the first defrustimpl argument must have type R.ref(...) or R.mut_ref(...)"
    end

    %AST.TypeRef{mutable: mutable} = receiver.type
    receiver = %{receiver | name: :self, type: nil, receiver: true, mutable: mutable}
    %{function | args: [receiver | args], vis: vis}
  end

  defp method_ast(%AST.Function{}, _vis) do
    raise ArgumentError, "defrustimpl methods require a self argument"
  end

  defp impl_type!({:__aliases__, _, parts}, rust_modules) do
    rust_parts = Map.get(rust_modules, parts, Enum.map(parts, &Identifier.atom!/1))
    %AST.TypePath{parts: rust_parts}
  end

  defp impl_type!(part, _rust_modules) when is_atom(part),
    do: %AST.TypePath{parts: [Identifier.atom!(part)]}

  defp impl_type!(other, _rust_modules) do
    raise ArgumentError,
          "expected a Rust type alias in defrustimpl, got: #{Macro.to_string(other)}"
  end

  defp normalize_type(%Type{} = type, _aliases), do: type

  defp normalize_type(type_ast, _aliases) when is_binary(type_ast),
    do: type_ast |> A.type() |> rust_ast_type()

  defp normalize_type(%{__struct__: _module} = type_ast, _aliases) do
    if AST.type_node?(type_ast) do
      rust_ast_type(type_ast)
    else
      raise ArgumentError, "expected RustQ type AST node, got: #{inspect(type_ast)}"
    end
  end

  defp normalize_type(type_ast, aliases), do: Type.parse(type_ast, aliases)

  defp rust_ast_type(type_ast) do
    %Type{
      kind: rust_ast_type_kind(type_ast),
      rust: Rust.render_type(type_ast),
      ast: type_ast
    }
  end

  defp rust_ast_type_kind(%AST.TypeNifResult{}), do: :nif_result
  defp rust_ast_type_kind(%AST.TypeResult{}), do: :result
  defp rust_ast_type_kind(%AST.TypeOption{}), do: :option
  defp rust_ast_type_kind(%AST.TypeUnit{}), do: :unit
  defp rust_ast_type_kind(_type_ast), do: :type

  defp do_build_ast(
         {call_ast, body_ast, attrs, rust_module, rust_impl},
         specs,
         type_aliases,
         rust_modules,
         env,
         external_callables,
         external_static_types,
         rust_macros
       ) do
    {name, _meta, arg_asts} = call_ast
    arg_names = Enum.map(arg_asts, &arg_name!/1)
    {arg_types, return_type} = find_spec!(specs, name, length(arg_names), type_aliases)
    arg_types = if nif_attrs?(attrs), do: Enum.map(arg_types, &nif_input_type/1), else: arg_types

    body_ast = expand_body_macros(body_ast, env)
    uses_nif_env? = contains_nif_env?(body_ast)

    if uses_nif_env? and not nif_attrs?(attrs) do
      raise ArgumentError, "nif_env/0 is only available inside defnif"
    end

    if uses_nif_env? and :env in arg_names do
      raise ArgumentError, "nif_env/0 reserves the Rust argument name env"
    end

    implicit_env? = nif_attrs?(attrs) and uses_nif_env?

    args =
      Enum.zip(arg_names, Enum.map(arg_types, & &1.ast))
      |> Enum.map(fn {name, type} -> %AST.FunctionArg{name: name, type: type} end)
      |> maybe_prepend_nif_env(implicit_env?)

    vars = Map.merge(external_static_types, Map.new(Enum.zip(arg_names, arg_types)))

    body =
      Lower.quoted_body(body_ast, return_type, vars,
        rust_modules: rust_modules,
        callables: spec_callables(specs, type_aliases) ++ external_callables,
        rust_macros: rust_macros
      )

    lifetime =
      if implicit_env? or Enum.any?(arg_types ++ [return_type], &Type.lifetime?/1), do: :a

    ast = %AST.Function{
      name: name,
      args: args,
      returns: return_type.ast,
      body: body,
      lifetimes: List.wrap(lifetime),
      attrs: attrs
    }

    %{ast: ast, rust_module: rust_module, rust_impl: rust_impl}
  end

  defp nif_attrs?(attrs) do
    Enum.any?(attrs, &match?(%AST.Attribute{path: [:rustler, :nif]}, &1))
  end

  defp contains_nif_env?(body_ast) do
    {_body, found?} =
      Macro.prewalk(body_ast, false, fn
        {:nif_env, _meta, []} = call, _found? -> {call, true}
        ast, found? -> {ast, found?}
      end)

    found?
  end

  defp maybe_prepend_nif_env(args, true) do
    [
      %AST.FunctionArg{
        name: :env,
        type: %AST.TypePath{parts: [:Env], lifetimes: [:a]}
      }
      | args
    ]
  end

  defp maybe_prepend_nif_env(args, false), do: args

  defp nif_input_type(%Type{kind: :binary}) do
    %Type{
      kind: :binary,
      rust: "Binary<'a>",
      ast: %AST.TypePath{parts: [:Binary], lifetimes: [:a]}
    }
  end

  defp nif_input_type(type), do: type

  @spec raise_defrust_diagnostic(Macro.t(), Macro.t(), Exception.t() | Diagnostic.t()) ::
          no_return()
  defp raise_defrust_diagnostic(call_ast, body_ast, cause) do
    {name, _meta, arg_asts} = call_ast
    arity = length(arg_asts || [])

    Diagnostic.defrust(
      :build_failed,
      body_ast,
      "failed to build defrust #{name}/#{arity}: #{diagnostic_cause_message(cause)}",
      details: %{function: name, arity: arity, cause: cause}
    )
  end

  defp diagnostic_cause_message(%Diagnostic{} = diagnostic), do: diagnostic.message
  defp diagnostic_cause_message(error), do: Exception.message(error)

  @doc false
  def expand_body_macros(body_ast, env) do
    body_ast
    |> Macro.prewalk(fn ast -> expand_body_macro(ast, env) end)
    |> flatten_blocks()
  end

  defp expand_body_macro({name, _meta, args} = ast, env) when is_atom(name) and is_list(args) do
    if kernel_or_rusty_form?(name) do
      ast
    else
      expanded = Macro.expand(ast, env)

      if expanded == ast do
        ast
      else
        expand_body_macros(expanded, env)
      end
    end
  end

  defp expand_body_macro(ast, _env), do: ast

  defp flatten_blocks({:__block__, meta, expressions}) do
    {:__block__, meta, Enum.flat_map(expressions, &flatten_block_expression/1)}
  end

  defp flatten_blocks(ast), do: ast

  defp flatten_block_expression({:__block__, _meta, expressions}),
    do: Enum.flat_map(expressions, &flatten_block_expression/1)

  defp flatten_block_expression(expression), do: [expression]

  defp kernel_or_rusty_form?(name) do
    name in [
      :=,
      :!,
      :..,
      :!=,
      :!==,
      :%,
      :{},
      :*,
      :+,
      :++,
      :-,
      :--,
      :/,
      :|>,
      :<,
      :<=,
      :==,
      :===,
      :=~,
      :>,
      :>=,
      :__aliases__,
      :__block__,
      :and,
      :case,
      :cast,
      :cond,
      :div,
      :fn,
      :for,
      :if,
      :in,
      :is_nil,
      :not,
      :or,
      :ref,
      :mut_ref,
      :deref,
      :expr!,
      :pat!,
      :stmt!,
      :arm!,
      :raw_expr!,
      :raw_pat!,
      :raw_stmt!,
      :raw_arm!,
      :rem,
      :unwrap!
    ]
  end

  defp type_items(%Type{
         kind: :enum,
         rust: rust_name,
         meta: %{variants: variants, elixir_name: elixir_name}
       }) do
    enum = %AST.Enum{
      name: Identifier.atom!(rust_name),
      vis: :pub,
      derive: [:Clone, :Copy, :Debug, :Eq, :PartialEq],
      variants:
        variants
        |> Enum.map(&Decoder.rust_variant/1)
        |> Enum.map(&%AST.EnumVariant{name: Identifier.atom!(&1)})
    }

    decoder = %AST.Function{
      name: Identifier.atom!("decode_#{elixir_name}_atom"),
      vis: :pub,
      args: [%AST.FunctionArg{name: :value, type: %AST.TypePath{parts: [:Atom]}}],
      returns: %AST.TypeNifResult{inner: %AST.TypePath{parts: [rust_name]}},
      body:
        A.block do
          A.return do
            A.match A.var(:value) do
              Enum.map(variants, fn variant ->
                A.arm %AST.PatAtomGuard{name: variant} do
                  A.return(A.ok(A.path([rust_name, Decoder.rust_variant(variant)])))
                end
              end) ++ [A.badarg_arm()]
            end
          end
        end
    }

    [enum, decoder]
  end

  defp type_items(%Type{kind: :rust_enum, meta: %{rust_name: rust_name, variants: variants}}) do
    [enum_item(rust_name, variants)]
  end

  defp type_items(%Type{
         kind: :tuple_enum,
         rust: rust_name,
         meta: %{elixir_name: elixir_name, variants: variants}
       }) do
    enum = enum_item(rust_name, variants)

    decoder = %AST.Function{
      name: Identifier.atom!("decode_#{elixir_name}"),
      vis: :pub,
      args: [%AST.FunctionArg{name: :term, type: %AST.TypePath{parts: [:Term], lifetimes: [:a]}}],
      returns: %AST.TypeNifResult{inner: %AST.TypePath{parts: [rust_name]}},
      lifetimes: [:a],
      body: Decoder.tuple_enum_decoder_body(rust_name, variants)
    }

    [enum, decoder]
  end

  defp type_items(%Type{kind: kind, rust: rust_name, meta: %{target: %Type{} = target}})
       when kind in [:alias, :resource] do
    [%AST.TypeAlias{name: Identifier.atom!(rust_name), type: target.ast, vis: :pub}]
  end

  defp type_items(%Type{kind: :struct, meta: %{rust_name: rust_name, fields: fields}}) do
    {lifetime?, decodable?} = struct_field_traits(fields)
    lifetime = if lifetime?, do: :a

    struct = %AST.Struct{
      name: Identifier.atom!(rust_name),
      vis: :pub,
      derive: [:Clone, :Debug],
      lifetimes: List.wrap(lifetime),
      fields: Enum.map(fields, &Decoder.struct_field_ast/1)
    }

    if decodable? do
      decoder = %AST.Function{
        name: Identifier.atom!("decode_#{Macro.underscore(rust_name)}"),
        vis: :pub,
        args: [
          %AST.FunctionArg{name: :term, type: %AST.TypePath{parts: [:Term], lifetimes: [:a]}}
        ],
        returns: %AST.TypeNifResult{
          inner: %AST.TypePath{parts: [rust_name], lifetimes: List.wrap(lifetime)}
        },
        lifetimes: [:a],
        body:
          A.block do
            A.return(
              A.ok(A.struct_expr([rust_name], Enum.map(fields, &Decoder.struct_decoder_field/1)))
            )
          end
      }

      [struct, decoder]
    else
      [struct]
    end
  end

  defp type_items(_type), do: []

  defp enum_item(rust_name, variants) do
    %AST.Enum{
      name: Identifier.atom!(rust_name),
      vis: :pub,
      derive: [:Clone, :Debug],
      variants:
        Enum.map(variants, fn {tag, types} ->
          %AST.EnumVariant{
            name: tag |> Decoder.rust_variant() |> Identifier.atom!(),
            tuple: Enum.map(types, & &1.ast)
          }
        end)
    }
  end

  defp struct_field_traits(fields) do
    Enum.reduce(fields, {false, true}, fn {_name, type, _presence} = field,
                                          {lifetime?, decodable?} ->
      {lifetime? or Type.lifetime?(type), decodable? and decodable_struct_field?(field)}
    end)
  end

  defp decodable_struct_field?({_name, %Type{kind: :type, ast: %AST.TypeRaw{}}, _presence}),
    do: false

  defp decodable_struct_field?({_name, %Type{kind: :alias, meta: %{target: target}}, _presence}),
    do: decodable_type?(target)

  defp decodable_struct_field?({_name, %Type{} = type, _presence}), do: decodable_type?(type)

  defp decodable_type?(%Type{kind: :type, ast: %AST.TypeRaw{}}), do: false
  defp decodable_type?(%Type{kind: :fn}), do: false
  defp decodable_type?(%Type{kind: :rust_enum}), do: false
  defp decodable_type?(%Type{kind: :alias, meta: %{target: target}}), do: decodable_type?(target)
  defp decodable_type?(%Type{}), do: true

  defp arg_name!({name, _meta, context}) when is_atom(name) and is_atom(context), do: name

  defp arg_name!(other) do
    raise ArgumentError, "unsupported defrust argument: #{Macro.to_string(other)}"
  end

  @doc false
  @spec callables_from_specs([term()], map()) :: [Callable.t()]
  def callables_from_specs(specs, type_aliases), do: spec_callables(specs, type_aliases)

  defp spec_callables(specs, type_aliases) do
    Enum.flat_map(specs, fn
      {:spec, {:"::", _, [{name, _, args}, return]}, _location} when is_atom(name) ->
        case parse_callable_spec(name, args, return, type_aliases) do
          {:ok, callable} -> [callable]
          :error -> []
        end

      _other ->
        []
    end)
  end

  defp parse_callable_spec(name, args, return, type_aliases) do
    {:ok,
     Callable.from_spec(
       name,
       Enum.map(args, &Type.parse(&1, type_aliases)),
       Type.parse(return, type_aliases)
     )}
  rescue
    ArgumentError -> :error
    FunctionClauseError -> :error
  end

  defp find_spec!(specs, name, arity, type_aliases) do
    Enum.find_value(specs, fn
      {:spec, {:"::", _, [{^name, _, args}, return]}, _location} when length(args) == arity ->
        {Enum.map(args, &Type.parse(&1, type_aliases)), Type.parse(return, type_aliases)}

      _other ->
        nil
    end) ||
      raise ArgumentError,
            "missing @spec for defrust #{name}/#{arity}; define @spec immediately before or before defrust"
  end
end
