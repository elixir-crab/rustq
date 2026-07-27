defmodule RustQ.Meta do
  @moduledoc """
  Valid-Elixir macro frontend for generating RustQ Rust fragments.

  `defrust` captures a normal Elixir function-shaped body plus its preceding
  `@spec`, lowers that quoted Elixir AST to Rust, and exposes generated Rust
  items through `__rustq_items__/0` and `__rustq_source__/0`.

  `defrustmod` is for RustQ-owned Rust module structure. Prefer its block form
  when RustQ is generating the Rust module and the nested functions. Do not use
  it as a hand-written alias for Rust modules/types that are owned by another
  generator or crate; those callers should derive/render their Rust paths at
  their own codegen boundary instead of pretending external Rust modules are
  Elixir modules.

  `defrustimpl` groups `defrust` declarations into an inherent or trait Rust
  `impl` block. The first argument of each method remains valid Elixir and must
  be typed as `R.ref(Target.t())` or `R.mut_ref(Target.t())`; RustQ renders it
  as `&self` or `&mut self` respectively.

  `defrustmacro` defines a small `macro_rules!` item from a Rusty-Elixir body.
  Its arguments are Rust macro fragments (`:expr` by default, with `:ty`
  supported for type arguments) while the body still uses ordinary Rusty-Elixir
  forms such as calls, `decode_as!/2`, and inference-backed propagation.

  Prefer `@spec` plus `defrust` for user-facing Rusty Elixir. Generated or
  external Rust paths should normally be expressed as ordinary remote types such
  as `GeneratedOpts.OvalOpts.t(R.lifetime(:a))`; use `RustQ.Type` markers such
  as `R.ref/1`, `R.nif_result/1`, `R.unit/0`, `R.slice/1`, and `R.lifetime/1`
  only where Elixir typespecs need Rust-specific precision.
  `RustQ.Meta.AST.functions/1` and `function!/2` are the public structural
  bridge for generators that consume compiled `defrust` functions; they are not
  the normal function-authoring surface.

  Preferred Rusty-Elixir body forms are ordinary Elixir where possible:

    * final `:ok` under `NifResult<()>` returns `Ok(())`
    * `name = expression` lowers to Rust `let name = expression`
    * method calls, field access, aliases, and Elixir tuples lower to their Rust
      equivalents
    * plural alias calls such as `Atoms.fill()` lower to snake-case Rust module
      calls such as `atoms::fill()`
    * ordinary Elixir macros are expanded before lowering, so reusable body
      fragments can use `defmacro`, `quote`, and `unquote`
    * fallible calls in argument, return, case-scrutinee, `some(...)`,
      `decode_as!`, and many local-binding positions can infer Rust `?` from
      type metadata
    * `unwrap!(expression)` is the explicit spelling for Rust `expression?`;
      prefer inference when callable metadata is available
    * `ref(expression)` / `mut_ref(expression)` spell explicit Rust borrows;
      many ordinary calls infer borrows from expected argument types
    * `deref(expression)` spells Rust dereference and can propagate fallible
      reference access such as `args.first().ok_or(badarg())`
    * Option branching should use Elixir `case`, for example
      `case maybe do {:some, value} -> ...; :none -> ... end`; do not introduce
      Rust-shaped `if_let` syntax at the authoring layer

  Escape hatches such as `raw_expr!` remain low-level last resorts, not the
  normal way to reference project-owned Rust modules or types.
  """

  alias RustQ.Binding.Source
  alias RustQ.Meta.AST
  alias RustQ.Meta.Options
  alias RustQ.Meta.RustMacro
  alias RustQ.Meta.Type
  alias RustQ.Rust
  alias RustQ.Rust.Identifier

  @doc false
  defmacro __using__(opts) do
    %{
      rust_sources: rust_sources,
      rust_packages: rust_packages,
      callable_modules: callable_modules,
      static_types: static_types
    } =
      Options.validate!(opts, __CALLER__)

    quote do
      import RustQ.Meta
      alias RustQ.Clippy, as: Clippy
      Module.register_attribute(__MODULE__, :rustq_defs, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_stub_keys, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_nif_stub_keys, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_macros, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_mod_aliases, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_rust_sources, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_rust_packages, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_callable_modules, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_static_types, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_current_rust_mod, accumulate: false)
      Module.register_attribute(__MODULE__, :rustq_current_rust_impl, accumulate: false)
      @rustq_rust_sources unquote(Macro.escape(List.wrap(rust_sources)))
      @rustq_rust_packages unquote(Macro.escape(List.wrap(rust_packages)))
      @rustq_callable_modules unquote(Macro.escape(List.wrap(callable_modules)))
      @rustq_static_types unquote(Macro.escape(List.wrap(static_types)))
      Module.register_attribute(__MODULE__, :nif, accumulate: false)
      Module.register_attribute(__MODULE__, :allow, accumulate: true)
      @before_compile RustQ.Meta
    end
  end

  defmacro defrustmod(alias_ast, opts \\ []) do
    mapping = rust_module_mapping!(alias_ast, opts)

    quote do
      @rustq_mod_aliases unquote(Macro.escape(mapping))
    end
  end

  defmacro defrustmod(alias_ast, opts, do: block) do
    {alias_parts, rust_parts} = rust_module_mapping!(alias_ast, opts)

    quote do
      @rustq_mod_aliases unquote(Macro.escape({alias_parts, rust_parts}))
      Module.put_attribute(__MODULE__, :rustq_current_rust_mod, unquote(Macro.escape(rust_parts)))
      unquote(block)
      Module.delete_attribute(__MODULE__, :rustq_current_rust_mod)
    end
  end

  @doc """
  Groups Rusty-Elixir methods into an inherent or trait Rust `impl` block.

  The first argument of every nested `defrust` declaration is the receiver. Its
  spec must use `R.ref(...)` for `&self` or `R.mut_ref(...)` for `&mut self`.

      defrustimpl Counter, vis: :crate do
        @spec increment(R.mut_ref(R.path(:Counter)), R.i64()) :: R.i64()
        defrust increment(self, amount), do: self.value + amount
      end

      defrustimpl Display, for: Counter do
        @spec fmt(R.ref(R.path(:Counter)), R.path(:Formatter)) :: R.path(:FmtResult)
        defrust fmt(self, formatter), do: formatter.write_str(self.label.as_str())
      end

  Supported options are `:for`, `:vis`, `:attrs`, and `:lifetimes`.
  """
  defmacro defrustimpl(target_or_trait_ast, opts \\ [], do: block) do
    {target_ast, trait_ast, opts} =
      case Keyword.pop(opts, :for) do
        {nil, opts} -> {target_or_trait_ast, nil, opts}
        {target_ast, opts} -> {target_ast, target_or_trait_ast, opts}
      end

    impl = %{
      target: target_ast,
      trait: trait_ast,
      vis: Keyword.get(opts, :vis),
      attrs: Keyword.get(opts, :attrs, []),
      lifetimes: Keyword.get(opts, :lifetimes, [])
    }

    quote do
      Module.put_attribute(__MODULE__, :rustq_current_rust_impl, unquote(Macro.escape(impl)))
      unquote(block)
      Module.delete_attribute(__MODULE__, :rustq_current_rust_impl)
    end
  end

  defmacro defrust(call_ast, do: body_ast) do
    rust_definition(call_ast, body_ast, :public_helper)
  end

  @doc "Declares a private generated Rust helper from a valid Elixir-shaped body."
  defmacro defrustp(call_ast, do: body_ast) do
    rust_definition(call_ast, body_ast, :private_helper)
  end

  @doc "Declares a public NIF entrypoint generated from a valid Elixir-shaped body."
  defmacro defnif(call_ast, do: body_ast) do
    rust_definition(call_ast, body_ast, :nif)
  end

  defp rust_definition(call_ast, body_ast, kind) do
    {name, args} = call_name_args!(call_ast)
    arity = length(args || [])
    stub_key = {name, arity}

    stub_args =
      if arity == 0, do: [], else: for(index <- 1..arity//1, do: Macro.var(:"_arg#{index}", nil))

    definition =
      quote do
        @rustq_defs {unquote(Macro.escape(call_ast)), unquote(Macro.escape(body_ast)),
                     RustQ.Meta.Attrs.take_pending(__MODULE__),
                     RustQ.Meta.Attrs.current_rust_mod(__MODULE__),
                     RustQ.Meta.Attrs.current_rust_impl(__MODULE__)}
      end

    quote do
      unquote(nif_default(kind))
      unquote(nif_stub_key(kind, stub_key))
      unquote(definition)
      unquote(rust_stub(kind, stub_key, name, stub_args))
    end
  end

  defp nif_default(:nif) do
    quote do
      if Module.get_attribute(__MODULE__, :nif) == nil do
        Module.put_attribute(__MODULE__, :nif, true)
      end
    end
  end

  defp nif_default(_kind), do: nil

  defp nif_stub_key(:nif, stub_key) do
    quote do
      @rustq_nif_stub_keys unquote(Macro.escape(stub_key))
    end
  end

  defp nif_stub_key(_kind, _stub_key), do: nil

  defp rust_stub(:nif, _stub_key, _name, _stub_args), do: nil

  defp rust_stub(:private_helper, stub_key, name, stub_args) do
    escaped_stub_key = Macro.escape(stub_key)

    quote do
      unless unquote(escaped_stub_key) in Module.get_attribute(
               __MODULE__,
               :rustq_stub_keys
             ) do
        @rustq_stub_keys unquote(escaped_stub_key)
        @doc false

        defp unquote(name)(unquote_splicing(stub_args)),
          do: :erlang.nif_error(:rustq_defrust_stub)
      end
    end
  end

  defp rust_stub(:public_helper, stub_key, name, stub_args) do
    escaped_stub_key = Macro.escape(stub_key)

    quote do
      unless unquote(escaped_stub_key) in Module.get_attribute(
               __MODULE__,
               :rustq_stub_keys
             ) do
        @rustq_stub_keys unquote(escaped_stub_key)
        @doc false

        def unquote(name)(unquote_splicing(stub_args)),
          do: :erlang.nif_error(:rustq_defrust_stub)
      end
    end
  end

  defp call_name_args!({:when, _, [call_ast, _guard]}), do: call_name_args!(call_ast)
  defp call_name_args!({name, _meta, args}) when is_atom(name), do: {name, args || []}

  defp call_name_args!(other) do
    raise ArgumentError, "expected a function head, got: #{Macro.to_string(other)}"
  end

  defmacro defrustmacro(call_ast, do: body_ast) do
    quote do
      @rustq_macros {unquote(Macro.escape(call_ast)), unquote(Macro.escape(body_ast)),
                     RustQ.Meta.Attrs.current_rust_mod(__MODULE__)}
    end
  end

  defmacro __before_compile__(env), do: build_before_compile(env)

  defp build_before_compile(env) do
    %{
      built_asts: built_asts,
      built_macros: built_macros,
      local_callables: local_callables,
      rust_macros: rust_macros,
      type_aliases: type_aliases,
      rust_modules: rust_modules
    } = compile_context(env)

    asts = Enum.map(built_asts, & &1.ast)
    macro_items = Enum.map(built_macros, &Map.take(&1, [:name, :ast, :rust_module]))
    type_asts = AST.build_type_asts(type_aliases)
    type_items = type_asts
    rust_items = AST.group_items(built_macros ++ built_asts, rust_modules)
    items = type_items ++ rust_items

    type_source = Rust.render_all(type_items)
    function_source = Rust.render_all(rust_items)

    source = [type_source, function_source] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

    values = [
      asts: asts,
      macro_items: macro_items,
      rust_macros: rust_macros,
      type_aliases: type_aliases,
      type_asts: type_asts,
      type_items: type_items,
      items: items,
      local_callables: local_callables,
      source: source,
      nif_stub_keys:
        env.module
        |> Module.get_attribute(:rustq_nif_stub_keys)
        |> List.wrap()
        |> Enum.reverse()
    ]

    exports = exports(values)

    case Module.get_attribute(env.module, :rustq_native_opts) do
      nil -> exports
      opts -> RustQ.Native.__compile_native__(env, values, opts, exports)
    end
  end

  defp exports(values) do
    definitions = [
      {:__rustq_asts__, values[:asts]},
      {:__rustq_macro_items__, values[:macro_items]},
      {:__rustq_macro_definitions__, values[:rust_macros]},
      {:__rustq_types__, values[:type_aliases]},
      {:__rustq_type_asts__, values[:type_asts]},
      {:__rustq_type_items__, values[:type_items]},
      {:__rustq_items__, values[:items]},
      {:__rustq_callables__, values[:local_callables]},
      {:__rustq_source__, values[:source]}
    ]

    metadata = Enum.map(definitions, &export_definition/1)
    {:__block__, [], metadata ++ nif_stub_definitions(values[:nif_stub_keys])}
  end

  defp nif_stub_definitions(stub_keys) do
    stub_keys
    |> Enum.uniq()
    |> Enum.map(fn {name, arity} ->
      stub_args = for index <- 1..arity//1, do: Macro.var(:"_arg#{index}", nil)
      {name, stub_args}
    end)
    |> Enum.map(fn {name, stub_args} ->
      quote do
        def unquote(name)(unquote_splicing(stub_args)),
          do: :erlang.nif_error(:rustq_nif_not_loaded)
      end
    end)
  end

  defp export_definition({name, value}) do
    quote do
      @doc false
      def unquote(name)(), do: unquote(Macro.escape(value))
    end
  end

  defp compile_context(env) do
    defs =
      env.module
      |> Module.get_attribute(:rustq_defs)
      |> List.wrap()
      |> Enum.reverse()
      |> normalize_definitions()

    macro_defs = Module.get_attribute(env.module, :rustq_macros) |> List.wrap() |> Enum.reverse()
    specs = Module.get_attribute(env.module, :spec) |> List.wrap()
    type_aliases = env.module |> Module.get_attribute(:type) |> Type.type_aliases()
    rust_modules = env.module |> Module.get_attribute(:rustq_mod_aliases) |> rust_module_map()
    local_callables = AST.callables_from_specs(specs, type_aliases)
    external_callables = Source.external_callables(env.module)

    external_static_types =
      Map.merge(
        Source.external_static_types(env.module),
        configured_static_types(env.module, type_aliases)
      )

    rust_macros = RustMacro.definitions(macro_defs)
    rust_macro_index = RustMacro.index!(rust_macros)
    callables = local_callables ++ external_callables

    %{
      built_asts:
        Enum.map(
          defs,
          &AST.build_ast(
            &1,
            specs,
            type_aliases,
            rust_modules,
            env,
            external_callables,
            external_static_types,
            rust_macro_index
          )
        ),
      built_macros: RustMacro.items(rust_macros, rust_modules, env, callables, rust_macro_index),
      local_callables: local_callables,
      rust_macros: rust_macros,
      type_aliases: type_aliases,
      rust_modules: rust_modules
    }
  end

  defp normalize_definitions(definitions) do
    definitions
    |> Enum.chunk_by(&definition_key/1)
    |> Enum.map(&normalize_definition_group/1)
  end

  defp definition_key({call_ast, _body, _attrs, rust_module, rust_impl}) do
    {name, args} = call_name_args!(call_ast)
    {name, length(args), rust_module, rust_impl}
  end

  defp normalize_definition_group([
         {call_ast, _body, _attrs, _rust_module, _rust_impl} = definition
       ]) do
    {_head, guard} = split_guarded_head(call_ast)
    {_name, args} = call_name_args!(call_ast)

    if guard == nil and Enum.all?(args, &plain_argument?/1) do
      definition
    else
      combine_definitions([definition])
    end
  end

  defp normalize_definition_group(definitions), do: combine_definitions(definitions)

  defp combine_definitions(
         [
           {first_call, _body, attrs, rust_module, rust_impl} | _
         ] = definitions
       ) do
    {name, args} = call_name_args!(first_call)
    arity = length(args)

    if arity == 0 do
      raise ArgumentError, "multiple zero-arity defrust clauses are not supported"
    end

    function_args = for index <- 1..arity, do: Macro.var(:"arg#{index}", nil)

    scrutinee =
      case function_args do
        [argument] -> argument
        arguments -> {:{}, [], arguments}
      end

    clauses =
      Enum.map(definitions, fn {call_ast, body, _clause_attrs, _rust_module, _rust_impl} ->
        {call_ast, guard} = split_guarded_head(call_ast)
        {_name, _meta, patterns} = call_ast

        pattern =
          case patterns do
            [pattern] -> pattern
            patterns -> {:{}, [], patterns}
          end

        pattern = if guard, do: {:when, [], [pattern, guard]}, else: pattern
        {:->, [], [[pattern], body]}
      end)

    {{name, [], function_args}, {:case, [], [scrutinee, [do: clauses]]}, attrs, rust_module,
     rust_impl}
  end

  defp split_guarded_head({:when, _, [call_ast, guard]}), do: {call_ast, guard}
  defp split_guarded_head(call_ast), do: {call_ast, nil}

  defp plain_argument?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp plain_argument?(_argument), do: false

  defp configured_static_types(module, type_aliases) do
    module
    |> Module.get_attribute(:rustq_static_types)
    |> List.wrap()
    |> List.flatten()
    |> Map.new(fn {name, type_ast} -> {name, RustQ.Spec.type(type_ast, type_aliases)} end)
  end

  defp rust_module_mapping!(alias_ast, opts) do
    alias_parts = alias_parts!(alias_ast)
    rust_parts = opts |> Keyword.fetch!(:as) |> List.wrap()
    {alias_parts, rust_parts}
  end

  defp alias_parts!({:__aliases__, _, parts}), do: parts

  defp alias_parts!(atom) when is_atom(atom) do
    atom
    |> Module.split()
    |> Enum.map(&Identifier.atom!/1)
  end

  defp alias_parts!(other) do
    raise ArgumentError, "expected alias in defrustmod, got: #{Macro.to_string(other)}"
  end

  defp rust_module_map(values), do: values |> List.wrap() |> Map.new()
end
