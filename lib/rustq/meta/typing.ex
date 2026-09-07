defmodule RustQ.Meta.Typing do
  @moduledoc false

  alias RustQ.Binding.Index, as: BindingIndex
  alias RustQ.Meta.Core.Call
  alias RustQ.Meta.Inference
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Lower.Stdlib
  alias RustQ.Meta.Lower.Stdlib.TypeContext, as: StdlibTypeContext
  alias RustQ.Meta.Pattern
  alias RustQ.Meta.StandardPointer
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  defmodule Env do
    @moduledoc false
    defstruct vars: %{}, callables: %BindingIndex{}, rust_modules: %{}, type_aliases: %{}

    @type t :: %__MODULE__{
            type_aliases: map(),
            vars: %{optional(atom()) => Type.t()},
            callables: BindingIndex.t(),
            rust_modules: %{optional([atom()]) => [atom()]}
          }
  end

  defmodule Check do
    @moduledoc false
    defstruct [:type, :coercion]

    @type coercion ::
            :none
            | :propagate
            | :some
            | :to_vec
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

  def synth({:deref, _meta, [expression]}, %Env{} = env) do
    case synth(expression, env) do
      %Type{} = type -> Type.ref_inner(type)
      nil -> nil
    end
  end

  def synth({:unwrap!, _meta, [expression]}, %Env{} = env) do
    case synth(expression, env) do
      %Type{} = type -> Type.inner(type)
      nil -> nil
    end
  end

  def synth({:|>, _meta, [left, right]}, %Env{} = env) do
    case Call.pipe_remote(left, right) do
      {:ok, call} -> synth(call, env)
      :unsupported -> nil
    end
  end

  def synth(call_ast, %Env{} = env) do
    case synth_stdlib(call_ast, env) do
      {:ok, %Type{} = type} ->
        type

      :unsupported ->
        Lower.callable_return_type(
          call_ast,
          callables: env.callables,
          rust_modules: env.rust_modules,
          vars: env.vars
        ) || synth_method_call(call_ast, env)
    end
  end

  def synth(ast, opts) when is_list(opts), do: synth(ast, env(opts))

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
    actual = synth(ast, env)

    %Check{type: actual, coercion: coercion(actual, expected)}
  end

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
    rhs_types = non_propagating_let_rhs_types(expressions, env)

    inferred_types =
      Map.new(inferred, fn {name, type} ->
        {name, inferred_binding_type(type, Map.get(rhs_types, name))}
      end)

    Map.merge(rhs_types, inferred_types)
  end

  defp stdlib_type_context(%Env{} = env) do
    %StdlibTypeContext{
      type_of: &synth(&1, env),
      type_with_vars: fn ast, vars -> synth(ast, %{env | vars: Map.merge(env.vars, vars)}) end
    }
  end

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

        case inner.ast do
          %AST.TypePath{parts: [:String], generics: []} -> inner
          %AST.TypeVec{} -> inner
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

  defp synth_method_call({{:., _, [receiver, :as_ref]}, _meta, []}, %Env{} = env) do
    receiver
    |> synth(env)
    |> option_as_ref_type()
  end

  defp synth_method_call({{:., _, [receiver, :ok_or]}, _meta, [_error]}, %Env{} = env) do
    receiver
    |> synth(env)
    |> option_ok_or_type()
  end

  defp synth_method_call({{:., _, [_receiver, :atom_to_string]}, _meta, []}, %Env{}),
    do: result_type(RustQ.Spec.type(quote(do: String.t())))

  defp synth_method_call({{:., _, [receiver, :get]}, _meta, [_index]}, %Env{} = env) do
    receiver
    |> synth(env)
    |> slice_get_type()
  end

  defp synth_method_call({{:., _, [receiver, :first]}, _meta, []}, %Env{} = env) do
    receiver
    |> synth(env)
    |> slice_get_type()
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
    receiver
    |> synth(env)
    |> callable_target_from_type()
    |> then(&BindingIndex.return_type(env.callables, &1, function, length(args)))
  end

  defp field_type(%Type{} = type, field) when is_atom(field) do
    type
    |> field_receiver_type()
    |> struct_field_type(field)
  end

  defp field_type(_type, _field), do: nil

  defp field_receiver_type(%Type{} = type), do: Type.ref_inner(type) || type

  defp slice_get_type(%Type{} = type) do
    cond do
      inner = Type.vec_inner(type) -> option_type(ref_type(inner))
      inner = Type.slice_inner(type) -> option_type(ref_type(inner))
      true -> nil
    end
  end

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

  defp option_as_ref_type(%Type{kind: :option} = type) do
    case Type.inner(type) do
      %Type{} = inner -> option_type(ref_type(inner))
      nil -> nil
    end
  end

  defp option_as_ref_type(_type), do: nil

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

  defp inferred_binding_type(%Type{} = inferred, %Type{} = rhs) do
    if propagated_rhs_for_inferred_binding?(rhs, inferred), do: inferred, else: rhs
  end

  defp inferred_binding_type(inferred, _rhs), do: inferred

  defp propagated_rhs_for_inferred_binding?(%Type{} = rhs, %Type{} = inferred) do
    Type.propagates?(rhs) and
      (not Type.propagates?(inferred) or Type.compatible_with_expected?(Type.inner(rhs), inferred))
  end

  defp non_propagating_let_rhs_types(expressions, %Env{} = env) do
    expressions
    |> Enum.flat_map(&let_rhs_type(&1, env))
    |> Map.new()
    |> Map.reject(fn {_name, type} -> Type.propagates?(type) end)
  end

  defp let_rhs_type({:=, _meta, [{name, _pattern_meta, context}, expression]}, %Env{} = env)
       when is_atom(name) and is_atom(context) do
    case synth(expression, env) do
      %Type{} = type -> [{name, type}]
      nil -> []
    end
  end

  defp let_rhs_type(_expression, _env), do: []

  defp coercion(%Type{} = actual, %Type{} = expected) do
    direct_coercion(actual, expected) ||
      propagation_coercion(actual, expected) ||
      value_coercion(actual, expected) || :unknown
  end

  defp coercion(_actual, _expected), do: :unknown

  defp direct_coercion(actual, expected) do
    cond do
      Type.compatible?(actual, expected) -> :none
      option_ref_adapter_compatible?(actual, expected) -> :as_ref
      option_adapter_compatible?(actual, expected) -> :none
      true -> nil
    end
  end

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
      ref_inner_compatible?(actual, expected) -> borrow_coercion(expected)
      vec_slice_compatible?(actual, expected) -> :borrow
      slice_vec_compatible?(actual, expected) -> :to_vec
      Type.compatible_with_expected?(actual, expected) -> :none
      true -> nil
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
