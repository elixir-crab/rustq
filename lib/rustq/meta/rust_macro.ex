defmodule RustQ.Meta.RustMacro do
  @moduledoc """
  `defrustmacro`: a small Rust `macro_rules!` helper written in Rusty-Elixir. Collects a
  module's definitions, lowers each body to a macro item, and builds calls to it.
  """

  alias RustQ.Diagnostic
  alias RustQ.Meta.AST, as: MetaAST
  alias RustQ.Meta.Lower
  alias RustQ.Meta.Type
  alias RustQ.Rust
  alias RustQ.Rust.AST

  defmodule Definition do
    @moduledoc """
    A `defrustmacro` as written: its name, its fragment arguments (`:expr`, `:ty`, `:ident`,
    `:literal`, labeled or repeated), and the Rust module it belongs to.
    """

    @enforce_keys [:name, :args, :call_ast, :body_ast]
    defstruct [:name, :args, :call_ast, :body_ast, :rust_module]

    @type fragment :: :expr | :ty | :ident | :literal
    @type arg ::
            {atom(), fragment()}
            | {:labeled, atom(), atom(), fragment()}
            | {:repeat, atom(), [arg()]}
    @type t :: %__MODULE__{
            name: atom(),
            args: [arg()],
            call_ast: Macro.t(),
            body_ast: Macro.t(),
            rust_module: [atom()] | nil
          }
  end

  defmodule Item do
    @moduledoc "A lowered `defrustmacro`: the `macro_rules!` item and its Rust module."

    @enforce_keys [:name, :ast]
    defstruct [:name, :ast, :rust_module]

    @type t :: %__MODULE__{name: atom(), ast: AST.MacroItem.t(), rust_module: [atom()] | nil}
  end

  @type index :: %{optional(atom()) => Definition.t()}

  @doc "Builds definitions from the module's `defrustmacro` attributes."
  @spec definitions([{Macro.t(), Macro.t(), [atom()] | nil}]) :: [Definition.t()]
  def definitions(attributes) do
    Enum.map(attributes, fn {call_ast, body_ast, rust_module} ->
      {name, args} = signature!(call_ast)

      %Definition{
        name: name,
        args: args,
        call_ast: call_ast,
        body_ast: body_ast,
        rust_module: rust_module
      }
    end)
  end

  @doc "Indexes definitions by name, raising when two share one."
  @spec index!([Definition.t()]) :: index()
  def index!(definitions) do
    Enum.reduce(definitions, %{}, fn %Definition{name: name, call_ast: call_ast} = definition,
                                     index ->
      if Map.has_key?(index, name) do
        Diagnostic.defrust(
          :duplicate_defrustmacro,
          call_ast,
          "duplicate defrustmacro #{name}",
          suggestion: "Use a single defrustmacro per Rust macro name for now."
        )
      end

      Map.put(index, name, definition)
    end)
  end

  @doc "Lowers each definition to its `macro_rules!` item."
  @typedoc """
  What lowering a module's definitions needs: its Rust module mappings, environment, callables,
  `defrustmacro` index, and type aliases, which the macros' specs and bodies name.
  """
  @type context :: %{
          rust_modules: map(),
          env: Macro.Env.t(),
          callables: [term()],
          index: index(),
          type_aliases: map()
        }

  @spec items([Definition.t()], context()) :: [Item.t()]
  def items(definitions, context) do
    Enum.map(definitions, &item(&1, context))
  end

  @doc "The fragment kinds of a definition's non-repeated arguments, in order."
  @spec fragments(Definition.t()) :: [Definition.fragment()]
  def fragments(%Definition{args: args}) do
    args
    |> Enum.reject(&match?({:repeat, _name, _args}, &1))
    |> Enum.map(fn
      {_name, fragment} -> fragment
      {:labeled, _label, _name, fragment} -> fragment
    end)
  end

  @doc "Builds an item-position call to the macro with the given argument values."
  @spec item_call(Definition.t(), keyword()) :: AST.MacroItemCall.t()
  def item_call(%Definition{name: name, args: args}, values) when is_list(values) do
    value_map = Map.new(values)

    %AST.MacroItemCall{
      path: %AST.Path{parts: [name]},
      tokens: args |> item_call_tokens(value_map) |> List.flatten()
    }
  end

  defp item_call_tokens(args, values) do
    Enum.map(args, &item_call_arg(&1, values))
  end

  defp item_call_arg({:labeled, :fn, name, fragment}, values) do
    ["\n    fn ", call_labeled_value!(values, :fn, name, fragment), ";"]
  end

  defp item_call_arg({:labeled, label, name, fragment}, values) do
    [
      "\n    ",
      Atom.to_string(label),
      " ",
      call_labeled_value!(values, label, name, fragment),
      ";"
    ]
  end

  defp item_call_arg({name, fragment}, values) do
    ["\n    ", call_value!(values, name, fragment), ";"]
  end

  defp item_call_arg({:repeat, name, captures}, values) do
    rows = Map.fetch!(values, name)

    [
      "\n    ",
      Atom.to_string(name),
      " [\n",
      rows
      |> Enum.map(&["        ", item_call_repeat_row(captures, Map.new(&1))])
      |> Enum.intersperse("\n"),
      "\n    ]"
    ]
  end

  defp item_call_repeat_row(captures, row) do
    captures
    |> repeat_row_layout()
    |> Enum.map(fn
      {:capture, capture} -> capture_value(row, capture)
      token -> token
    end)
  end

  defp capture_value(row, {name, fragment}), do: call_value!(row, name, fragment)

  defp call_labeled_value!(values, label, name, fragment) do
    value =
      case Map.fetch(values, label) do
        {:ok, value} -> value
        :error -> Map.fetch!(values, name)
      end

    render_call_value(value, fragment)
  end

  defp call_value!(values, name, fragment),
    do: render_call_value(Map.fetch!(values, name), fragment)

  # Expression and type captures may be given as RustQ AST rather than source.
  defp render_call_value(%_{} = node, :ty), do: Rust.render_type(node)
  defp render_call_value(%_{} = node, :expr), do: Rust.render(node)
  defp render_call_value(value, :literal) when is_binary(value), do: inspect(value)
  defp render_call_value(value, :literal), do: to_string(value)
  defp render_call_value(value, :ident) when is_list(value), do: IO.iodata_to_binary(value)
  defp render_call_value(value, :ident), do: to_string(value)
  defp render_call_value(value, _fragment) when is_list(value), do: IO.iodata_to_binary(value)
  defp render_call_value(value, _fragment), do: to_string(value)

  defp item(%Definition{} = definition, context) do
    ast =
      case item_macro_body(definition.body_ast, definition, context) do
        {:ok, source} ->
          %AST.MacroItem{source: source}

        :error ->
          body_ast = MetaAST.expand_body_macros(definition.body_ast, context.env)
          body = Lower.quoted_body(body_ast, nil, %{}, lower_opts(definition, context))

          %AST.MacroItem{source: source(definition.name, definition.args, body)}
      end

    %Item{name: definition.name, ast: ast, rust_module: definition.rust_module}
  rescue
    error in Diagnostic.Error ->
      raise_diagnostic(definition, error.diagnostic)

    error in [ArgumentError, FunctionClauseError] ->
      raise_diagnostic(definition, error)
  end

  defp signature!({name, _meta, args}) when is_atom(name) and is_list(args) do
    {plain_args, keyword_args} = split_args(args)

    positional = Enum.map(plain_args, &arg!(&1, :expr))
    annotated = Enum.map(keyword_args, &keyword_arg!/1)

    args = positional ++ annotated
    validate_unique_args!(name, args)

    {name, args}
  end

  defp signature!(other) do
    Diagnostic.defrust(
      :invalid_defrustmacro_signature,
      other,
      "invalid defrustmacro signature",
      suggestion: "Use defrustmacro name(arg, type_arg: :ty) do ... end."
    )
  end

  defp split_args(args) do
    case Enum.split(args, max(length(args) - 1, 0)) do
      {plain, [[{_name, _fragment} | _] = keyword]} -> {plain, keyword}
      {_plain, [keyword]} when is_list(keyword) -> invalid_keyword_args!(keyword)
      {plain, []} -> {plain, []}
      {plain, [last]} -> {plain ++ [last], []}
    end
  end

  defp validate_unique_args!(macro_name, args) do
    args
    |> capture_names()
    |> duplicate_capture()
    |> case do
      nil ->
        :ok

      duplicate ->
        Diagnostic.defrust(
          :duplicate_defrustmacro_argument,
          duplicate,
          "duplicate argument #{duplicate} in defrustmacro #{macro_name}"
        )
    end
  end

  defp duplicate_capture(names) do
    {_seen, duplicate} =
      Enum.reduce_while(names, {MapSet.new(), nil}, fn name, {seen, _duplicate} ->
        if MapSet.member?(seen, name) do
          {:halt, {seen, name}}
        else
          {:cont, {MapSet.put(seen, name), nil}}
        end
      end)

    duplicate
  end

  defp capture_names(args) do
    Enum.flat_map(args, fn
      {name, _fragment} -> [name]
      {:labeled, _label, name, _fragment} -> [name]
      {:repeat, name, args} -> [name | capture_names(args)]
    end)
  end

  @spec invalid_keyword_args!(term()) :: no_return()
  defp invalid_keyword_args!(args) do
    Diagnostic.defrust(
      :invalid_defrustmacro_argument,
      args,
      "invalid defrustmacro annotated arguments",
      suggestion: "Use keyword annotations such as type: :ty."
    )
  end

  defp keyword_arg!({label, {:repeat, _meta, [[do: body]]}}) when is_atom(label) do
    {:repeat, label, repeat_args!(body)}
  end

  defp keyword_arg!({label, {name, _meta, [fragment]}})
       when is_atom(label) and is_atom(name) and is_atom(fragment) do
    {:labeled, label, name, fragment!(name, fragment)}
  end

  defp keyword_arg!({arg_name, fragment}), do: arg!(arg_name, fragment)

  defp repeat_args!({:__block__, _meta, expressions}), do: Enum.map(expressions, &repeat_arg!/1)
  defp repeat_args!(expression), do: [repeat_arg!(expression)]

  defp repeat_arg!({name, _meta, [fragment]}) when is_atom(name) and is_atom(fragment),
    do: {name, fragment!(name, fragment)}

  defp repeat_arg!(other) do
    Diagnostic.defrust(
      :invalid_defrustmacro_repeat,
      other,
      "invalid defrustmacro repeat capture",
      suggestion: "Use captures such as field_id(:literal) inside repeat blocks."
    )
  end

  defp arg!({name, _meta, context}, fragment) when is_atom(name) and is_atom(context),
    do: arg!(name, fragment)

  defp arg!(name, fragment) when is_atom(name), do: {name, fragment!(name, fragment)}

  defp arg!(arg, _fragment) do
    Diagnostic.defrust(
      :invalid_defrustmacro_argument,
      arg,
      "invalid defrustmacro argument",
      suggestion: "Use plain variables and optional keyword fragment annotations."
    )
  end

  defp fragment!(_name, fragment) when fragment in [:expr, :ty, :ident, :literal], do: fragment

  defp fragment!(name, fragment) when is_atom(name) do
    Diagnostic.defrust(
      :unsupported_defrustmacro_fragment,
      name,
      "unsupported Rust macro fragment #{inspect(fragment)} for #{name}",
      suggestion: "Currently defrustmacro supports :expr and :ty fragments."
    )
  end

  defp item_macro_body({:__block__, _meta, expressions}, definition, context) do
    pairs = item_defrust_pairs(expressions)

    if pairs == [] do
      :error
    else
      {:ok, item_macro_source(definition, pairs, context)}
    end
  end

  defp item_macro_body(expression, definition, context),
    do: item_macro_body({:__block__, [], [expression]}, definition, context)

  defp item_defrust_pairs(expressions), do: item_defrust_pairs(expressions, nil, [])

  defp item_defrust_pairs([], _pending_spec, acc), do: Enum.reverse(acc)

  defp item_defrust_pairs([expression | rest], pending_spec, acc) do
    case {spec_ast(expression), defrust_ast(expression)} do
      {{spec_call, return_ast}, nil} ->
        item_defrust_pairs(rest, {spec_call, return_ast}, acc)

      {nil, {call_ast, body_ast}} when not is_nil(pending_spec) ->
        item_defrust_pairs(rest, nil, [{pending_spec, {call_ast, body_ast}} | acc])

      _ ->
        item_defrust_pairs(rest, nil, acc)
    end
  end

  defp spec_ast({:@, _meta, [{:spec, _spec_meta, [{:"::", _op_meta, [call_ast, return_ast]}]}]}),
    do: {call_ast, return_ast}

  defp spec_ast(_expression), do: nil

  defp lower_opts(definition, context) do
    [
      rust_modules: context.rust_modules,
      callables: context.callables,
      type_aliases: context.type_aliases,
      macro_vars: macro_var_map(definition.args),
      rust_macros: context.index
    ]
  end

  defp defrust_ast({:defrust, _meta, [call_ast, [do: body_ast]]}), do: {call_ast, body_ast}
  defp defrust_ast(_expression), do: nil

  defp item_macro_source(definition, pairs, context) do
    pattern = item_pattern(definition.args)

    expansion =
      Enum.map_join(pairs, "\n\n", fn {spec, defrust} ->
        item_function_expansion(definition, spec, defrust, context)
      end)

    "macro_rules! #{definition.name} {\n#{indent("(#{pattern}) => {\n#{indent(expansion)}\n};")}\n}"
  end

  defp item_function_expansion(definition, {spec_call, return_ast}, {call_ast, body_ast}, context) do
    {_spec_name, _spec_meta, arg_type_asts} = spec_call
    {name_ast, _call_meta, arg_asts} = call_ast

    arg_names = Enum.map(arg_asts, &capture_var_name!/1)
    arg_types = Enum.map(arg_type_asts, &Type.parse(&1, context.type_aliases))
    return_type = Type.parse(return_ast, context.type_aliases)
    vars = Map.new(Enum.zip(arg_names, arg_types))
    body = Lower.quoted_body(body_ast, return_type, vars, lower_opts(definition, context))

    function_expansion(
      name_ast,
      arg_names,
      arg_types,
      return_type,
      body,
      macro_var_map(definition.args)
    )
  end

  defp capture_var_name!({name, _meta, context}) when is_atom(name) and is_atom(context), do: name

  defp capture_var_name!(other) do
    Diagnostic.defrust(
      :invalid_defrustmacro_item_arg,
      other,
      "invalid defrustmacro item argument",
      suggestion: "Use plain captured argument names in inner defrust, such as defrust name(env)."
    )
  end

  defp item_pattern(args), do: Enum.map_join(args, "\n", &item_pattern_arg/1)

  defp item_pattern_arg({:labeled, :fn, name, fragment}), do: "fn $#{name}:#{fragment};"
  defp item_pattern_arg({:labeled, label, name, fragment}), do: "#{label} $#{name}:#{fragment};"
  defp item_pattern_arg({name, fragment}), do: "$#{name}:#{fragment};"

  defp item_pattern_arg({:repeat, name, args}) do
    pattern =
      args
      |> repeat_row_layout()
      |> Enum.map_join(fn
        {:capture, capture} -> capture_pattern(capture)
        token -> token
      end)

    "#{name} [$(#{pattern})*]"
  end

  # Captures are separated by commas, which may follow any fragment, including `expr`.
  defp repeat_row_layout(captures) do
    captures |> Enum.map(&capture/1) |> Enum.intersperse(", ") |> Kernel.++([";"])
  end

  defp capture(capture), do: {:capture, capture}

  defp capture_pattern({name, fragment}), do: "$#{name}:#{fragment}"

  defp function_expansion(name_ast, arg_names, arg_types, return_type, body, macro_vars) do
    name = macro_capture_source(name_ast, macro_vars)

    args =
      Enum.zip(arg_names, arg_types)
      |> Enum.map_join(", ", fn {arg_name, type} ->
        "#{macro_capture_source(arg_name, macro_vars)}: #{render_type(type)}"
      end)

    rendered_body = Enum.map_join(body, "\n", &render_macro_item_stmt/1)

    lifetime = if Enum.any?(arg_types ++ [return_type], &Type.lifetime?/1), do: "<'a>", else: ""

    "fn #{name}#{lifetime}(#{args}) -> #{render_type(return_type)} {\n#{indent(rendered_body)}\n}"
  end

  defp render_macro_item_stmt(stmt), do: Rust.render(stmt)

  defp macro_capture_source({name, _meta, args}, macro_vars)
       when is_atom(name) and is_list(args) do
    if Map.has_key?(macro_vars, name), do: "$#{name}", else: Atom.to_string(name)
  end

  defp macro_capture_source({name, _meta, context}, macro_vars)
       when is_atom(name) and is_atom(context) do
    if Map.has_key?(macro_vars, name), do: "$#{name}", else: Atom.to_string(name)
  end

  defp macro_capture_source(other, macro_vars) when is_atom(other) do
    if Map.has_key?(macro_vars, other), do: "$#{other}", else: Atom.to_string(other)
  end

  defp render_type(%Type{} = type), do: Rust.render_type(type.ast)

  defp macro_var_map(args) do
    args
    |> Enum.flat_map(fn
      {name, fragment} -> [{name, fragment}]
      {:labeled, _label, name, fragment} -> [{name, fragment}]
      {:repeat, _name, args} -> macro_var_map(args)
    end)
    |> Map.new()
  end

  defp source(name, args, body) do
    pattern = Enum.map_join(args, ", ", fn {arg_name, fragment} -> "$#{arg_name}:#{fragment}" end)

    rendered_body = Enum.map_join(body, "\n", &Rust.render/1)

    "macro_rules! #{name} {\n    (#{pattern}) => {{\n#{indent(rendered_body)}\n    }};\n}"
  end

  defp indent(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", &["        ", &1])
  end

  @spec raise_diagnostic(Definition.t(), term()) :: no_return()
  defp raise_diagnostic(%Definition{} = definition, cause) do
    Diagnostic.defrust(
      :defrustmacro_failed,
      definition.body_ast,
      "failed to build defrustmacro #{definition.name}/#{length(definition.args)}: #{diagnostic_message(cause)}",
      details: %{macro: definition.name, arity: length(definition.args), cause: cause}
    )
  end

  defp diagnostic_message(%Diagnostic{} = diagnostic), do: diagnostic.message
  defp diagnostic_message(error), do: Exception.message(error)
end
