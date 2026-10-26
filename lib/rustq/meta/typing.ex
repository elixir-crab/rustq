defmodule RustQ.Meta.Typing do
  @moduledoc """
  Synthesizes the type of a Rusty-Elixir expression and checks one against an expected type,
  deciding the coercion lowering applies: propagating with `?`, wrapping in `Some`, borrowing,
  dereferencing, or none.
  """

  alias RustQ.Binding.Index, as: BindingIndex
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Inference
  alias RustQ.Meta.Lower.Collection
  alias RustQ.Meta.Lower.Paths
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.Lowering.TypeContext, as: StdlibTypeContext
  alias RustQ.Meta.Pattern
  alias RustQ.Meta.StandardPointer
  alias RustQ.Meta.StdMethods
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Spec

  defmodule Env do
    @moduledoc """
    What typing knows: variable types, callables, Rust module aliases, and type aliases.
    """
    defstruct vars: %{}, callables: %BindingIndex{}, rust_modules: %{}, type_aliases: %{}

    @type t :: %__MODULE__{
            type_aliases: map(),
            vars: %{optional(atom()) => Type.t()},
            callables: BindingIndex.t(),
            rust_modules: %{optional([atom()]) => [atom()]}
          }
  end

  defmodule Check do
    @moduledoc """
    The result of checking an expression against an expected type: its type, when known, and
    the coercion that makes it fit, or `:unknown`.
    """
    defstruct [:type, :coercion]

    @type coercion ::
            :none
            | :propagate
            | :some
            | :to_vec
            | :deref
            | :borrow
            | :mut_borrow
            | :propagate_borrow
            | :propagate_mut_borrow
            | :as_ref
            | :propagate_as_ref
            | :unknown
    @type t :: %__MODULE__{type: Type.t() | nil, coercion: coercion()}
  end

  @type env_source :: Env.t() | keyword()

  @spec env(keyword()) :: Env.t()
  def env(opts \\ []) do
    %Env{
      type_aliases: Keyword.get(opts, :type_aliases, %{}),
      vars: Keyword.get(opts, :vars, %{}),
      callables: BindingIndex.new(Keyword.get(opts, :callables)),
      rust_modules: Keyword.get(opts, :rust_modules, %{})
    }
  end

  @spec synth(Macro.t(), env_source()) :: Type.t() | nil
  def synth({name, _meta, context}, %Env{vars: vars}) when is_atom(name) and is_atom(context) do
    Map.get(vars, name)
  end

  def synth({:__aliases__, _meta, parts}, %Env{vars: vars}) when is_list(parts) do
    parts
    |> List.last()
    |> then(&Map.get(vars, &1))
  end

  def synth({:match?, _meta, [_pattern, _expression]}, %Env{}),
    do: Type.parse(quote(do: boolean()), %{})

  def synth({:nif_env, _meta, []}, %Env{}) do
    %Type{
      kind: :path,
      rust: "Env<'a>",
      ast: %AST.TypePath{parts: [:Env], lifetimes: [:a]}
    }
  end

  def synth({:cast, _meta, [_expression, type_ast]}, %Env{type_aliases: aliases}) do
    RustQ.Spec.type(type_ast, aliases)
  end

  def synth({:decode_as!, _meta, [_expression, type_ast]}, %Env{type_aliases: aliases}) do
    RustQ.Spec.type(type_ast, aliases)
  end

  def synth({:decode_as, _meta, [_expression, type_ast]}, %Env{type_aliases: aliases}) do
    type_ast
    |> RustQ.Spec.type(aliases)
    |> result_type()
  end

  def synth({:some, _meta, [expression]}, %Env{} = env) do
    case synth(expression, env) do
      %Type{} = type when type.kind in [:result, :nif_result] ->
        type |> Type.inner() |> option_type()

      %Type{} = type ->
        option_type(type)

      nil ->
        nil
    end
  end

  # A struct update has the type of the struct it updates.
  def synth({:%{}, _meta, [{:|, _, [base, fields]}]}, %Env{} = env) when is_list(fields),
    do: synth(base, env)

  def synth({:ref, _meta, [expression]}, %Env{} = env) do
    case synth(expression, env) do
      %Type{} = type -> Type.ref(type)
      nil -> nil
    end
  end

  def synth({:deref, _meta, [expression]}, %Env{} = env) do
    case synth(expression, env) do
      %Type{} = type -> Type.ref_inner(type)
      nil -> nil
    end
  end

  def synth({:index, _meta, [collection, _index]}, %Env{} = env) do
    case synth(collection, env) do
      %Type{} = type -> indexed_type(Type.ref_inner(type) || type)
      nil -> nil
    end
  end

  def synth({:unwrap!, _meta, [expression]}, %Env{} = env) do
    case synth(expression, env) do
      %Type{} = type -> Type.inner(type)
      nil -> nil
    end
  end

  # `RustQ.Meta.Desugar`'s iteration of a list is the list, and enumerating a list pairs each
  # item with its index.
  def synth({:__rustq_items__, _meta, [list]}, %Env{} = env), do: synth(list, env)

  def synth({:|>, _meta, [list, {:enumerate, _, []}]}, %Env{} = env) do
    with %Type{} = list <- synth(list, env),
         %Type{} = item <- Type.vec_inner(list) || slice_item(list) do
      Type.vec(Type.tuple([RustQ.Spec.type(quote(do: RustQ.Type.usize())), item]))
    end
  end

  def synth({:|>, _meta, [left, right]}, %Env{} = env) do
    case Call.pipe_remote(left, right) do
      {:ok, call} -> synth(call, env)
      :unsupported -> synth_piped_call(left, right, env)
    end
  end

  # A tuple of expressions whose types are all known, such as a `case` on `{left, right}`.
  def synth({left, right}, %Env{} = env) when not is_atom(left),
    do: synth_tuple([left, right], env)

  def synth({:{}, _meta, [first | _rest] = elements}, %Env{} = env) when not is_atom(first),
    do: synth_tuple(elements, env)

  # Indexing a map reads a value, and indexing a list an item.
  def synth({{:., _, [Access, :get]}, _meta, [collection, _key]}, %Env{} = env) do
    with %Type{} = type <- synth(collection, env) do
      case Collection.keyed(type) do
        {:map, _key, value} -> declared(value, env)
        _list -> Type.vec_inner(Type.ref_inner(type) || type) || Type.slice_inner(type)
      end
    end
  end

  # A branching expression has the type of its first branch whose type is known, as `nil` and
  # `[]` have none; a `case` branch reads what its pattern binds from the subject.
  def synth({:case, _meta, [subject, [do: clauses]]}, %Env{} = env) when is_list(clauses) do
    subject_type = synth(subject, env)

    Enum.find_value(clauses, fn {:->, _, [[pattern], body]} ->
      synth(body, bind_pattern(unguarded(pattern), subject_type, env))
    end)
  end

  def synth({:if, _meta, [_condition, branches]}, %Env{} = env) when is_list(branches),
    do: Enum.find_value([:do, :else], &synth(Keyword.get(branches, &1), env))

  def synth({:cond, _meta, [[do: clauses]]}, %Env{} = env) when is_list(clauses),
    do: Enum.find_value(clauses, fn {:->, _, [_condition, body]} -> synth(body, env) end)

  def synth({:__block__, _meta, [_ | _] = expressions}, %Env{} = env),
    do: synth(List.last(expressions), env)

  # A list literal whose items all have one known type is a list of that type.
  def synth([first | rest], %Env{} = env) do
    with %Type{} = item <- synth(first, env),
         true <- Enum.all?(rest, &(synth(&1, env) == item)) do
      Type.vec(item)
    else
      _unknown -> nil
    end
  end

  # A comprehension collects its body's values into a list, or into the map or set `into:`
  # names, as `RustQ.Meta.Desugar` writes `Map.new/1,2` and `MapSet.new/1,2`.
  def synth({:for, _meta, [{:<-, _, _generator} | _rest] = args}, %Env{} = env) do
    {qualifiers, options} = Enum.split_while(args, &(not Keyword.keyword?(&1) or &1 == []))
    options = Enum.concat(options)

    with %Env{} = bound <- Enum.reduce_while(qualifiers, env, &bind_generator/2),
         {:ok, body} <- Keyword.fetch(options, :do),
         %Type{} = value <- synth(body, bound) do
      collected(Keyword.get(options, :into), value)
    else
      _unknown -> nil
    end
  end

  def synth(call_ast, %Env{} = env) do
    case synth_stdlib(call_ast, env) do
      {:ok, %Type{} = type} ->
        type

      :unsupported ->
        Paths.callable_return_type(
          call_ast,
          callables: env.callables,
          rust_modules: env.rust_modules,
          vars: env.vars
        ) || synth_method_call(call_ast, env)
    end
  end

  def synth(ast, opts) when is_list(opts), do: synth(ast, env(opts))

  defp slice_item(%Type{} = list) do
    case Type.slice_inner(list) do
      %Type{} = item -> Type.ref(item)
      nil -> nil
    end
  end

  defp bind_pattern({name, _meta, context}, %Type{} = item, %Env{} = env)
       when is_atom(name) and is_atom(context),
       do: %{env | vars: Map.put(env.vars, name, item)}

  # `{:some, value}` and `{:ok, value}` bind what the option or result holds.
  defp bind_pattern({:some, value}, %Type{kind: :option} = item, %Env{} = env),
    do: bind_inner(value, item, env)

  defp bind_pattern({:ok, value}, %Type{kind: kind} = item, %Env{} = env)
       when kind in [:result, :nif_result],
       do: bind_inner(value, item, env)

  defp bind_pattern(
         {left, right},
         %Type{kind: :tuple, meta: %{elements: [left_type, right_type]}},
         %Env{} = env
       ),
       do:
         env
         |> then(&bind_pattern(left, left_type, &1))
         |> then(&bind_pattern(right, right_type, &1))

  defp bind_pattern(_pattern, _item, %Env{} = env), do: env

  # A type named in Rust as one of the module's aliases is that alias, as `Table` read out of
  # a map of tables.
  defp declared(%Type{ast: %AST.TypePath{parts: [name], generics: []}} = type, %Env{} = env) do
    rust_name = to_string(name)

    Enum.find_value(env.type_aliases, type, fn {_key, alias} ->
      if alias.rust == rust_name, do: alias
    end)
  end

  defp declared(type, _env), do: type

  defp unguarded({:when, _, [pattern, _guard]}), do: pattern
  defp unguarded(pattern), do: pattern

  defp bind_inner(pattern, %Type{} = wrapper, %Env{} = env) do
    case Type.inner(wrapper) do
      %Type{} = inner -> bind_pattern(pattern, inner, env)
      nil -> env
    end
  end

  # Each generator binds its pattern to the items of its collection, in the variables the
  # earlier ones bound; filters bind nothing.
  defp bind_generator({:<-, _, [pattern, collection]}, %Env{} = env) do
    with %Type{} = list <- synth(collection, env),
         %Type{} = item <- Type.vec_inner(list) || slice_item(list) || keyed_item(list) do
      {:cont, bind_pattern(pattern, item, env)}
    else
      _unknown -> {:halt, nil}
    end
  end

  defp bind_generator(_filter, %Env{} = env), do: {:cont, env}

  # A map yields its keys and values, and a set its items, copied where that costs nothing and
  # borrowed otherwise, as `RustQ.Meta.Lower.Comprehension` iterates them.
  defp keyed_item(type) do
    case Collection.keyed(type) do
      {:map, key, value} -> Type.tuple([lent(key), lent(value)])
      {:set, item} -> lent(item)
      nil -> nil
    end
  end

  defp lent(type), do: if(Collection.copy?(type), do: type, else: Type.ref(type))

  defp collected(into, %Type{} = value) do
    case {Collection.keyed(constructed(into)), value} do
      {{:map, _, _}, %Type{kind: :tuple, meta: %{elements: [key, item]}}} ->
        Collection.map(key, item)

      {{:set, _}, value} ->
        Collection.set(value)

      {nil, value} ->
        Type.vec(value)

      _other ->
        nil
    end
  end

  # The collection type an `into:` constructor names, with types to be filled in.
  defp constructed({:%{}, _, []}), do: Collection.map(unknown(), unknown())

  defp constructed({{:., _, [{:__aliases__, _, [module]}, :new]}, _, []})
       when module in [:Map, :HashMap, :BTreeMap],
       do: Collection.map(unknown(), unknown())

  defp constructed({{:., _, [{:__aliases__, _, [module]}, :new]}, _, []})
       when module in [:MapSet, :HashSet, :BTreeSet],
       do: Collection.set(unknown())

  defp constructed(_into), do: nil

  defp unknown, do: %Type{kind: :type, rust: "_", ast: %AST.TypeRaw{source: "_"}, meta: %{}}

  defp indexed_type(%Type{} = type), do: Type.vec_inner(type) || Type.slice_inner(type)

  defp synth_stdlib({name, _meta, args} = call_ast, %Env{} = env)
       when is_atom(name) and is_list(args) do
    if BindingIndex.get(env.callables, nil, name, length(args)) do
      :unsupported
    else
      Stdlib.synth(call_ast, stdlib_type_context(env))
    end
  end

  defp synth_stdlib(call_ast, %Env{} = env),
    do: Stdlib.synth(call_ast, stdlib_type_context(env))

  @spec check(Macro.t(), Type.t(), env_source()) :: Check.t()
  def check(ast, %Type{} = expected, opts) when is_list(opts), do: check(ast, expected, env(opts))

  def check(ast, %Type{} = expected, %Env{} = env) do
    actual = synth(ast, env) || constructed_type(ast, expected)

    %Check{type: actual, coercion: coercion(actual, expected)}
  end

  # `HashSet.new()` makes a new value of the type its call names, which a reference to that
  # type borrows, though its type parameters come from where it goes.
  defp constructed_type(
         {{:., _, [{:__aliases__, _, [_ | _] = parts}, constructor]}, _, args},
         %Type{kind: :ref} = expected
       )
       when constructor in [:new, :with_capacity, :default] and is_list(args) do
    with %Type{ast: %AST.TypePath{parts: [_ | _] = type_parts}} = inner <-
           Type.ref_inner(expected),
         true <- List.last(type_parts) == List.last(parts) do
      inner
    else
      _other -> nil
    end
  end

  defp constructed_type(_ast, _expected), do: nil

  @spec expected_for_let(Macro.t(), Macro.t(), env_source()) :: Type.t() | nil
  def expected_for_let(pattern, expression, opts) when is_list(opts) do
    expected_for_let(pattern, expression, env(opts))
  end

  def expected_for_let(pattern, expression, %Env{} = env) do
    infer_pattern_type(pattern, env.vars) ||
      infer_pattern_type_from_call(pattern, expression, env) ||
      synth(expression, env)
  end

  @spec struct_field_type(Type.t(), atom()) :: Type.t() | nil
  def struct_field_type(%Type{} = type, field), do: Type.field_type(type, field)

  @spec infer_downstream_let_types([Macro.t()], env_source(), map()) :: %{
          optional(atom()) => Type.t()
        }
  def infer_downstream_let_types(expressions, env_or_opts, callbacks \\ %{})

  def infer_downstream_let_types(expressions, opts, callbacks) when is_list(opts) do
    infer_downstream_let_types(expressions, env(opts), callbacks)
  end

  def infer_downstream_let_types(expressions, %Env{} = env, callbacks) when is_map(callbacks) do
    callbacks = Map.merge(default_inference_callbacks(), callbacks)
    inferred = Inference.infer_downstream_let_types(expressions, env.vars, callbacks)
    all_rhs_types = let_rhs_types(expressions, env)
    rhs_types = Map.reject(all_rhs_types, fn {_name, type} -> Type.propagates?(type) end)

    # A binding takes its right-hand side's type over what its uses suggest, unless it is an
    # option or result those uses unwrap.
    inferred_types =
      Map.new(inferred, fn {name, type} ->
        {name, inferred_binding_type(type, Map.get(all_rhs_types, name))}
      end)

    # An option or result nothing downstream unwraps stays one, unless the binding's type is
    # already known.
    wrapped_types =
      Map.filter(all_rhs_types, fn {name, type} ->
        Type.propagates?(type) and not Map.has_key?(env.vars, name)
      end)

    wrapped_types
    |> Map.merge(rhs_types)
    |> Map.merge(inferred_types)
  end

  defp synth_tuple(elements, %Env{} = env) do
    types = Enum.map(elements, &synth(&1, env))
    if Enum.all?(types, &match?(%Type{}, &1)), do: Type.tuple(types)
  end

  defp stdlib_type_context(%Env{} = env), do: %StdlibTypeContext{env: env}

  defp default_inference_callbacks do
    %{
      return_type: fn _call -> nil end,
      local_argument_types: fn _name, _arity -> nil end,
      path_argument_types: fn _parts, _name, _arity -> nil end,
      method_argument_types: fn _target, _name, _arity -> nil end,
      target_type: fn _type -> nil end,
      method_receiver_type: fn _name, _arity -> nil end
    }
  end

  defp synth_method_call({{:., _, [receiver, method]}, _meta, [_operand]}, %Env{} = env)
       when method in [:checked_add, :checked_sub, :checked_mul, :checked_div, :checked_rem] do
    case synth(receiver, env) do
      %Type{} = type ->
        if Type.category(type) == :integer, do: Type.option(type)

      _unknown ->
        nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :lock]}, _meta, []}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{} = type -> StandardPointer.lock_result(type)
      nil -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :clone]}, _meta, []}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{} = type ->
        inner = Type.ref_inner(type) || type

        case inner do
          %Type{ast: %AST.TypePath{parts: [:String], generics: []}} -> inner
          %Type{ast: %AST.TypeVec{}} -> inner
          # Cloning a borrowed struct or option gives an owned one.
          %Type{kind: kind} when kind in [:struct, :option, :tuple, :enum, :alias] -> inner
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :ok]}, _meta, []}, %Env{} = env) do
    receiver
    |> synth(env)
    |> result_ok_type()
  end

  defp synth_method_call({{:., _, [receiver, :unwrap]}, _meta, []}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{} = type -> Type.inner(type)
      nil -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :unwrap_or]}, _meta, [_default]}, %Env{} = env) do
    receiver
    |> synth(env)
    |> option_unwrap_type()
  end

  # An option chained with another keeps its type.
  defp synth_method_call({{:., _, [receiver, method]}, _meta, [_other]}, %Env{} = env)
       when method in [:or, :or_else, :xor] do
    case synth(receiver, env) do
      %Type{kind: :option} = option -> option
      _unknown -> nil
    end
  end

  defp synth_method_call({{:., _, [_receiver, :to_string]}, _meta, []}, %Env{}),
    do: RustQ.Spec.type(quote(do: String.t()))

  defp synth_method_call({{:., _, [receiver, :as_slice]}, _meta, []}, %Env{} = env) do
    with %Type{} = type <- synth(receiver, env),
         %Type{} = item <- Type.vec_inner(type) || borrowed_vec_inner(type) do
      Type.slice_ref(item)
    else
      _unknown -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :to_vec]}, _meta, []}, %Env{} = env) do
    with %Type{} = type <- synth(receiver, env),
         %Type{} = item <-
           Type.slice_inner(type) || Type.vec_inner(type) || borrowed_vec_inner(type) do
      Type.vec(item)
    else
      _unknown -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, method]}, _meta, []}, %Env{} = env)
       when method in [:copied, :cloned] do
    with %Type{kind: :option} = option <- synth(receiver, env),
         %Type{} = inner <- Type.inner(option),
         %Type{} = value <- Type.ref_inner(inner) do
      option_type(value)
    else
      _unknown -> nil
    end
  end

  # Borrowing an option, owned or behind a reference, gives an option of a reference; an option
  # of a reference stays as it is.
  defp synth_method_call({{:., _, [receiver, :as_ref]}, _meta, []} = ast, %Env{} = env) do
    with %Type{} = type <- synth(receiver, env),
         %Type{kind: :option} = option <- Type.ref_inner(type) || type,
         %Type{} = inner <- Type.inner(option) do
      if Type.ref_inner(inner), do: option, else: Type.option(Type.ref(inner))
    else
      _unknown -> synth_method_return(ast, env)
    end
  end

  defp synth_method_call({{:., _, [receiver, :ok_or]}, _meta, [_error]}, %Env{} = env) do
    receiver
    |> synth(env)
    |> option_ok_or_type()
  end

  defp synth_method_call({{:., _, [_receiver, :atom_to_string]}, _meta, []}, %Env{}),
    do: result_type(RustQ.Spec.type(quote(do: String.t())))

  defp synth_method_call({{:., _, [receiver, :get]}, _meta, [_index]}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{} = type -> slice_get_type(type) || map_get_type(type)
      nil -> nil
    end
  end

  defp synth_method_call(
         {{:., _, [receiver, :and_then]}, _meta,
          [{:fn, _, [{:->, _, [[{name, _, context}], body]}]}]},
         %Env{} = env
       )
       when is_atom(name) and is_atom(context) do
    with %Type{kind: :option} = option <- synth(receiver, env),
         %Type{} = inner <- Type.inner(option),
         %Type{kind: :option} = chained <-
           synth(body, %{env | vars: Map.put(env.vars, name, inner)}) do
      chained
    else
      _unknown -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :first]}, _meta, []}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{} = type -> slice_get_type(type)
      nil -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, :map_get]}, _meta, [_key]}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{kind: :term} = term -> result_type(term)
      _unknown_receiver -> result_type(RustQ.Spec.type(quote(do: RustQ.Type.term())))
    end
  end

  defp synth_method_call({{:., _, [receiver, :filter]}, _meta, [_predicate]}, %Env{} = env) do
    case synth(receiver, env) do
      %Type{kind: :option} = option -> option
      _unknown -> nil
    end
  end

  defp synth_method_call(
         {{:., _, [receiver, :map]}, _meta, [{:__aliases__, _, [:Some]}]},
         %Env{} = env
       ) do
    case synth(receiver, env) do
      %Type{kind: :option} = option -> option_type(option)
      _unknown -> nil
    end
  end

  defp synth_method_call(
         {{:., _, [receiver, :map]}, _meta, [{:fn, _, [{:->, _, [[{name, _, context}], body]}]}]},
         %Env{} = env
       )
       when is_atom(name) and is_atom(context) do
    with %Type{kind: :option} = option <- synth(receiver, env),
         %Type{} = inner <- Type.inner(option),
         %Type{} = mapped <- synth(body, %{env | vars: Map.put(env.vars, name, inner)}) do
      option_type(mapped)
    else
      _unknown -> nil
    end
  end

  defp synth_method_call({{:., _, [receiver, field]}, _meta, []} = ast, %Env{} = env)
       when is_atom(field) do
    field_type(synth(receiver, env), field) || synth_method_return(ast, env)
  end

  defp synth_method_call({{:., _, [_receiver, function]}, _meta, args} = ast, %Env{} = env)
       when is_atom(function) and is_list(args),
       do: synth_method_return(ast, env)

  defp synth_method_call(_ast, _env), do: nil

  defp synth_method_return({{:., _, [receiver, function]}, _meta, args}, %Env{} = env)
       when is_atom(function) and is_list(args) do
    receiver_type = synth(receiver, env)

    receiver_type
    |> callable_target_from_type()
    |> then(&BindingIndex.return_type(env.callables, &1, function, length(args))) ||
      std_return(receiver_type, function)
  end

  # What a std method returns on a string, character, list, map, set, or option, as std's
  # source says; see `RustQ.Meta.StdMethods.returns/0`.
  defp std_return(%Type{} = receiver, function) do
    name = Atom.to_string(function)
    returns = StdMethods.returns()

    case Enum.find_value(std_receivers(receiver), &Map.get(returns, {&1, name})) do
      {parameters, returns} ->
        # Parameters past the receiver's own type arguments, as a `Vec`'s allocator, are unknown.
        arguments = type_arguments(receiver)

        bindings =
          Map.new(Enum.with_index(parameters), fn {parameter, index} ->
            {parameter, Enum.at(arguments, index)}
          end)

        returns |> Spec.from_syn() |> Type.substitute(bindings)

      nil ->
        nil
    end
  end

  defp std_return(_receiver, _function), do: nil

  # The type arguments of a std type, in the order it takes them: a list's item type, and a
  # map's key and value types.
  defp type_arguments(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: type_arguments(Type.ref_inner(type))

  defp type_arguments(%Type{kind: :option} = type), do: [Type.inner(type)]
  defp type_arguments(%Type{kind: :vec} = type), do: [Type.vec_inner(type)]
  defp type_arguments(%Type{kind: :slice} = type), do: [Type.slice_inner(type)]

  defp type_arguments(%Type{} = type) do
    case Collection.keyed(type) do
      {:map, key, value} -> [key, value]
      {:set, item} -> [item]
      nil -> []
    end
  end

  defp std_receivers(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: std_receivers(Type.ref_inner(type))

  defp std_receivers(%Type{kind: :vec}), do: ["Vec", "[T]"]
  defp std_receivers(%Type{kind: :slice}), do: ["[T]"]
  defp std_receivers(%Type{kind: :option}), do: ["Option"]

  defp std_receivers(%Type{ast: %AST.TypePath{parts: [:String], generics: []}}),
    do: ["String", "str"]

  defp std_receivers(%Type{rust: rust}) when rust in ["str", "&str"], do: ["str"]
  defp std_receivers(%Type{rust: "char"}), do: ["char"]

  defp std_receivers(%Type{ast: %AST.TypePath{parts: parts}}) do
    case List.last(parts) do
      collection when collection in [:HashMap, :HashSet] -> [Atom.to_string(collection)]
      _other -> []
    end
  end

  defp std_receivers(_type), do: []

  defp field_type(%Type{} = type, field) when is_atom(field) do
    type
    |> field_receiver_type()
    |> struct_field_type(field)
  end

  defp field_type(_type, _field), do: nil

  defp field_receiver_type(%Type{} = type), do: Type.ref_inner(type) || type

  # A pipe into a call that is not the module's own function calls the method on the value, as
  # lowering does.
  defp synth_piped_call(left, {name, meta, args}, %Env{} = env)
       when is_atom(name) and is_list(args) do
    Paths.callable_return_type(
      {name, meta, [left | args]},
      callables: env.callables,
      rust_modules: env.rust_modules,
      vars: env.vars
    ) || synth_method_call({{:., meta, [left, name]}, meta, args}, env)
  end

  defp synth_piped_call(_left, _right, %Env{}), do: nil

  defp map_get_type(%Type{} = type) do
    case Type.expected_value(Type.ref_inner(type) || type) do
      %Type{ast: %AST.TypePath{parts: [map], generics: [_key, value]}}
      when map in [:HashMap, :BTreeMap] ->
        option_type(ref_type(Type.ast_type(value)))

      _other ->
        nil
    end
  end

  defp slice_get_type(%Type{} = type) do
    cond do
      inner = Type.vec_inner(type) -> option_type(ref_type(inner))
      inner = borrowed_vec_inner(type) -> option_type(ref_type(inner))
      inner = Type.slice_inner(type) -> option_type(ref_type(inner))
      true -> nil
    end
  end

  defp borrowed_vec_inner(%Type{kind: kind} = type) when kind in [:ref, :mut_ref] do
    case Type.ref_inner(type) do
      %Type{} = vec -> Type.vec_inner(vec)
      nil -> nil
    end
  end

  defp borrowed_vec_inner(%Type{}), do: nil

  defp ref_type(%Type{} = inner), do: Type.ref(inner)
  defp option_type(%Type{} = inner), do: Type.option(inner)

  defp result_type(%Type{} = ok),
    do: %Type{
      kind: :result,
      rust: "Result<#{ok.rust}, rustler::Error>",
      ast: %AST.TypeResult{ok: ok.ast, error: %AST.TypePath{parts: [:rustler, :Error]}},
      meta: %{ok: ok}
    }

  defp result_ok_type(%Type{kind: kind} = type) when kind in [:result, :nif_result] do
    case Type.inner(type) do
      %Type{} = inner -> option_type(inner)
      nil -> nil
    end
  end

  defp result_ok_type(_type), do: nil

  defp option_ok_or_type(%Type{kind: :option} = type) do
    case Type.inner(type) do
      %Type{} = inner -> result_type(inner)
      nil -> nil
    end
  end

  defp option_ok_or_type(_type), do: nil

  defp option_unwrap_type(%Type{kind: :option} = type), do: Type.inner(type)

  defp option_unwrap_type(%Type{} = type) do
    case Type.inner(type) do
      %Type{kind: :option} = option_type ->
        if Type.propagates?(type), do: Type.inner(option_type)

      _other ->
        nil
    end
  end

  defp option_unwrap_type(_type), do: nil

  defp infer_pattern_type({name, _meta, context}, vars) when is_atom(name) and is_atom(context),
    do: Map.get(vars, name)

  defp infer_pattern_type(_pattern, _vars), do: nil

  defp infer_pattern_type_from_call(pattern, expression, %Env{} = env) do
    with [_ | _] = elements <- Pattern.tuple_elements(pattern),
         %Type{} = call_type <- synth(expression, env),
         true <- Type.propagates?(call_type),
         %Type{kind: :tuple, meta: %{elements: types}} = inner <- Type.inner(call_type),
         true <- length(elements) == length(types) do
      inner
    else
      _no_tuple_match -> nil
    end
  end

  # Elixir's integer, as a count is, takes the integer type its use needs, as a literal does.
  defp inferred_binding_type(%Type{} = inferred, %Type{kind: :i64} = rhs) do
    if Type.category(inferred) == :integer,
      do: inferred,
      else: rhs_unless_propagated(inferred, rhs)
  end

  defp inferred_binding_type(%Type{} = inferred, %Type{} = rhs),
    do: rhs_unless_propagated(inferred, rhs)

  defp inferred_binding_type(inferred, _rhs), do: inferred

  defp rhs_unless_propagated(inferred, rhs) do
    if propagated_rhs_for_inferred_binding?(rhs, inferred), do: inferred, else: rhs
  end

  defp propagated_rhs_for_inferred_binding?(%Type{} = rhs, %Type{} = inferred) do
    Type.propagates?(rhs) and
      (not Type.propagates?(inferred) or Type.compatible_with_expected?(Type.inner(rhs), inferred))
  end

  # Each binding's type, in order, so a later right-hand side reads the earlier bindings.
  defp let_rhs_types(expressions, %Env{} = env) do
    {types, _env} =
      Enum.reduce(expressions, {%{}, env}, fn expression, {types, env} ->
        bound = Map.new(let_rhs_type(expression, env))
        {Map.merge(types, bound), %{env | vars: Map.merge(env.vars, bound)}}
      end)

    types
  end

  defp let_rhs_type({:=, _meta, [{name, _pattern_meta, context}, expression]}, %Env{} = env)
       when is_atom(name) and is_atom(context) do
    case synth(expression, env) do
      %Type{} = type -> [{name, type}]
      nil -> []
    end
  end

  # A tuple of variables binds each to its element's type; a fallible right-hand side binds
  # what it gives on success, as it propagates its error.
  defp let_rhs_type({:=, _meta, [pattern, expression]}, %Env{} = env) do
    with [_ | _] = names <- Pattern.tuple_elements(pattern),
         %Type{kind: :tuple, meta: %{elements: elements}} <-
           expression |> synth(env) |> success_type(),
         true <- length(names) == length(elements) do
      for {{name, _meta, context}, %Type{} = type} <- Enum.zip(names, elements),
          is_atom(name) and is_atom(context) and name != :_,
          do: {name, type}
    else
      _other -> []
    end
  end

  defp let_rhs_type(_expression, _env), do: []

  defp success_type(%Type{} = type),
    do: if(Type.propagates?(type), do: Type.inner(type), else: type)

  defp success_type(type), do: type

  defp coercion(%Type{} = actual, %Type{} = expected) do
    direct_coercion(actual, expected) ||
      propagation_coercion(actual, expected) ||
      value_coercion(actual, expected) || :unknown
  end

  defp coercion(_actual, _expected), do: :unknown

  defp direct_coercion(actual, expected) do
    cond do
      Type.compatible?(actual, expected) -> :none
      inferred_option?(actual) and expected.kind == :option -> :none
      option_ref_adapter_compatible?(actual, expected) -> :as_ref
      option_adapter_compatible?(actual, expected) -> :none
      true -> nil
    end
  end

  # An `Option` whose item Rust infers, as `Enum.find_value/2` gives without a typed item.
  defp inferred_option?(%Type{kind: :option} = type),
    do: match?(%Type{ast: %AST.TypeRaw{source: "_"}}, Type.inner(type))

  defp inferred_option?(_type), do: false

  defp propagation_coercion(actual, expected) do
    if Type.propagates?(actual) do
      propagated_coercion(Type.inner(actual), expected)
    end
  end

  defp propagated_coercion(actual, expected) do
    cond do
      option_ref_adapter_compatible?(actual, expected) -> :propagate_as_ref
      Type.compatible_with_expected?(actual, expected) -> :propagate
      ref_inner_compatible?(actual, expected) -> propagate_borrow_coercion(expected)
      true -> nil
    end
  end

  defp value_coercion(actual, expected) do
    cond do
      expected.kind == :option and Type.compatible?(actual, Type.inner(expected)) -> :some
      copy_deref_compatible?(actual, expected) -> :deref
      ref_inner_compatible?(actual, expected) -> borrow_coercion(expected)
      vec_slice_compatible?(actual, expected) -> :borrow
      slice_vec_compatible?(actual, expected) -> :to_vec
      Type.compatible_with_expected?(actual, expected) -> :none
      true -> nil
    end
  end

  # A borrowed number, boolean, or tuple of them is copied out where its value is expected.
  defp copy_deref_compatible?(%Type{kind: :ref} = actual, %Type{} = expected) do
    case Type.ref_inner(actual) do
      %Type{} = inner -> copy?(expected) and Type.compatible?(inner, expected)
      nil -> false
    end
  end

  defp copy_deref_compatible?(_actual, _expected), do: false

  defp copy?(%Type{kind: :alias, meta: %{target: %Type{} = target}}), do: copy?(target)

  defp copy?(%Type{} = type) do
    case Type.category(Type.expected_value(type)) do
      category when category in [:number, :integer, :boolean, :enum] -> type.kind != :rust_enum
      {:tuple, elements} -> Enum.all?(elements, &copy?/1)
      _other -> false
    end
  end

  defp option_adapter_compatible?(%Type{} = actual, %Type{} = expected) do
    case expected_option_type(expected) do
      %Type{} = option -> Type.compatible?(actual, option)
      nil -> false
    end
  end

  defp option_ref_adapter_compatible?(%Type{kind: :option} = actual, %Type{} = expected) do
    with %Type{} = expected_option <- expected_option_type(expected),
         %Type{kind: :ref} = expected_inner <- Type.inner(expected_option),
         %Type{} = actual_inner <- Type.inner(actual) do
      Type.compatible?(actual_inner, Type.ref_inner(expected_inner))
    else
      _other -> false
    end
  end

  defp option_ref_adapter_compatible?(_actual, _expected), do: false

  defp expected_option_type(%Type{kind: :option} = type), do: type

  defp expected_option_type(%Type{kind: :impl_trait, meta: %{traits: traits}}) do
    Enum.find_value(traits, fn
      %Type{meta: %{syn_name: "Into", args: [%Type{kind: :option} = option]}} -> option
      %Type{} = trait -> expected_option_type(trait)
      _trait -> nil
    end)
  end

  defp expected_option_type(%Type{}), do: nil

  defp ref_inner_compatible?(%Type{} = actual, %Type{} = expected) do
    case Type.ref_inner(expected) do
      %Type{} = inner ->
        Type.compatible?(actual, inner) or vec_slice_compatible?(actual, inner) or
          string_str_compatible?(actual, inner)

      nil ->
        false
    end
  end

  defp string_str_compatible?(%Type{} = actual, %Type{} = expected) do
    type_name(actual) == "String" and type_name(expected) == "str"
  end

  defp type_name(%Type{} = type) do
    type.meta[:syn_name] || type.rust || Type.callable_target(type)
  end

  defp slice_vec_compatible?(%Type{} = actual, %Type{} = expected) do
    with %Type{} = slice_inner <- Type.slice_inner(actual),
         %Type{} = vec_inner <- Type.vec_inner(expected) do
      Type.compatible?(slice_inner, vec_inner)
    else
      _other -> false
    end
  end

  defp vec_slice_compatible?(%Type{} = actual, %Type{} = expected_inner) do
    with %Type{} = vec_inner <- Type.vec_inner(actual),
         %Type{} = slice_inner <- Type.slice_inner(expected_inner) do
      Type.compatible?(vec_inner, slice_inner)
    else
      _other -> false
    end
  end

  defp borrow_coercion(%Type{kind: :mut_ref}), do: :mut_borrow
  defp borrow_coercion(%Type{}), do: :borrow

  defp propagate_borrow_coercion(%Type{kind: :mut_ref}), do: :propagate_mut_borrow
  defp propagate_borrow_coercion(%Type{}), do: :propagate_borrow

  defp callable_target_from_type(%Type{} = type), do: Type.callable_target(type)
  defp callable_target_from_type(_type), do: nil
end
