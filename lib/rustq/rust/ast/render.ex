defmodule RustQ.Rust.AST.Render do
  @moduledoc false

  alias RustQ.Diagnostic
  alias RustQ.Native.Nif

  alias RustQ.Rust.AST.{
    Arm,
    ArrayLiteral,
    Assign,
    AssignOp,
    AtomValue,
    Attribute,
    BinaryOp,
    BlockExpr,
    Break,
    ByteString,
    Cast,
    Closure,
    Const,
    Continue,
    Derive,
    EarlyReturn,
    Enum,
    EnumVariant,
    Err,
    EscapeExpr,
    ExprStmt,
    Field,
    For,
    Function,
    FunctionArg,
    If,
    IfLet,
    Impl,
    Index,
    Let,
    LetElse,
    Literal,
    LocalCall,
    Loop,
    MacroCall,
    MacroCapture,
    MacroItem,
    MacroItemCall,
    MacroRepeat,
    MacroRepeatExpr,
    MacroRule,
    MacroRules,
    MacroVar,
    Match,
    MethodCall,
    Module,
    NifRaiseAtom,
    None,
    Ok,
    PatAtomGuard,
    PatErr,
    Path,
    PathCall,
    PatLiteral,
    PatNone,
    PatOk,
    PatPath,
    PatPathTuple,
    PatSlice,
    PatSome,
    PatStruct,
    PatTuple,
    PatVar,
    PatWildcard,
    Range,
    Ref,
    Return,
    Some,
    Static,
    Struct,
    StructField,
    StructLiteral,
    TokenMacro,
    Try,
    Tuple,
    TypeAlias,
    TypeArray,
    TypeBareFn,
    TypeImplTrait,
    TypeNifResult,
    TypeOption,
    TypePath,
    TypeRaw,
    TypeRef,
    TypeResult,
    TypeSlice,
    TypeTuple,
    TypeUnit,
    TypeVec,
    UnaryOp,
    Use,
    Var,
    VecLiteral
  }

  def render_item(%Use{} = item), do: render_native(item)
  def render_item(%Module{} = item), do: render_native(item)
  def render_item(%Const{} = item), do: render_native(item)
  def render_item(%Static{} = item), do: render_native(item)
  def render_item(%TypeAlias{} = item), do: render_native(item)
  def render_item(%MacroItem{} = item), do: render_macro_item(item)

  def render_item(%MacroItemCall{} = item), do: render_macro_item_call(item)
  def render_item(%MacroRules{} = item), do: render_macro_rules(item)

  def render_item(%Impl{} = item), do: render_native(item)
  def render_item(%Function{} = item), do: render_native(item)
  def render_item(%Struct{} = item), do: render_native(item)
  def render_item(%Enum{} = item), do: render_native(item)

  def render_file(items) do
    items
    |> List.wrap()
    |> Elixir.Enum.map_join("\n", &render_item/1)
  end

  def render_function(%Function{} = function), do: render_item(function)

  defp render_native(item) do
    Nif.render_ast(item)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Diagnostic.render(
        :native_render_failed,
        item,
        "native AST rendering failed for #{inspect(item.__struct__)}: #{Exception.message(error)}",
        details: %{ast_module: item.__struct__, cause: error},
        snippet: inspect(item, pretty: true, limit: 20)
      )
  end

  def render_use(%Use{parts: parts}) when is_list(parts),
    do: ["use ", Elixir.Enum.map_join(parts, "::", &to_string/1), ";"]

  def render_use(%Use{group: {base, names}}) when is_list(base) and is_list(names) do
    [
      "use ",
      Elixir.Enum.map_join(base, "::", &to_string/1),
      "::{",
      names |> Elixir.Enum.map(&render_use_group_member/1) |> Elixir.Enum.intersperse(", "),
      "};"
    ]
  end

  def render_use(%Use{tree: tree}), do: ["use ", tree, ";"]

  def render_module(%Module{} = module) do
    items = module.items |> Elixir.Enum.map(&render_item/1) |> Elixir.Enum.join("\n")

    [
      render_vis(module.vis),
      "mod ",
      Atom.to_string(module.name),
      " {\n",
      indent(items),
      "\n}"
    ]
  end

  def render_const(%Const{} = const) do
    [
      render_vis(const.vis),
      "const ",
      Atom.to_string(const.name),
      ": ",
      render_type(const.type),
      " = ",
      render_expr(const.expr),
      ";"
    ]
  end

  def render_static(%Static{} = static) do
    mutable = if static.mutable, do: "mut ", else: ""

    [
      render_vis(static.vis),
      "static ",
      mutable,
      Atom.to_string(static.name),
      ": ",
      render_type(static.type),
      " = ",
      render_expr(static.expr),
      ";"
    ]
  end

  def render_type_alias(%TypeAlias{} = alias_item) do
    [
      render_vis(alias_item.vis),
      "type ",
      Atom.to_string(alias_item.name),
      " = ",
      render_type(alias_item.type),
      ";"
    ]
  end

  def render_macro_item(%MacroItem{source: source}), do: source

  def render_macro_rules(%MacroRules{name: name, rules: rules, attrs: attrs}) do
    rendered_rules =
      rules
      |> Elixir.Enum.map(&render_macro_rule/1)
      |> Elixir.Enum.join("\n")

    [
      render_attrs(attrs),
      "macro_rules! ",
      Atom.to_string(name),
      " {\n",
      indent(rendered_rules),
      "\n}"
    ]
    |> IO.iodata_to_binary()
  end

  def render_macro_rule(%MacroRule{pattern: pattern, expansion: expansion}) do
    [
      "(",
      render_macro_tokens(pattern),
      ") => {\n",
      indent(render_macro_tokens(expansion)),
      "\n};"
    ]
    |> IO.iodata_to_binary()
  end

  def render_macro_tokens(tokens), do: Elixir.Enum.map(tokens, &render_macro_token/1)

  defp render_macro_token(%MacroVar{name: name, fragment: fragment}) do
    ["$", Atom.to_string(name), ":", Atom.to_string(fragment)]
  end

  defp render_macro_token(%MacroCapture{name: name}), do: ["$", Atom.to_string(name)]

  defp render_macro_token(%MacroRepeat{tokens: tokens, separator: separator, operator: operator}) do
    ["$(", render_macro_tokens(tokens), ")", separator || "", Atom.to_string(operator)]
  end

  defp render_macro_token(%Literal{} = literal), do: render_expr(literal)
  defp render_macro_token(%Path{} = path), do: render_expr(path)
  defp render_macro_token(token) when is_atom(token), do: Atom.to_string(token)
  defp render_macro_token(token) when is_binary(token), do: token

  def render_macro_item_call(%MacroItemCall{path: path, tokens: tokens}) when is_list(tokens) do
    [render_expr(path), "! { ", render_macro_tokens(tokens), " }"]
  end

  def render_macro_item_call(%MacroItemCall{path: path, args: args}) do
    [render_expr(path), "! { ", Elixir.Enum.map_join(args, ", ", &render_macro_arg/1), ", }"]
  end

  defp render_macro_arg({:literal, value}), do: inspect(value)
  defp render_macro_arg({name, value}), do: [to_string(name), " = ", inspect(value)]
  defp render_macro_arg(value), do: to_string(value)

  def render_impl(%Impl{} = impl) do
    items = impl.items |> Elixir.Enum.map(&render_impl_item/1) |> Elixir.Enum.join("\n")
    trait = if impl.trait, do: [render_trait(impl.trait), " for "], else: []

    lifetimes =
      if impl.lifetimes == [], do: [], else: ["<", render_lifetimes(impl.lifetimes), ">"]

    [
      render_attrs(impl.attrs),
      "impl",
      lifetimes,
      " ",
      trait,
      render_type(impl.target),
      " {\n",
      indent(items),
      "\n}"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_impl_item(%Function{} = function), do: do_render_function(function)
  defp render_impl_item(item), do: render_item(item)

  defp do_render_function(%Function{} = function) do
    args =
      Elixir.Enum.map_join(function.args, ", ", &render_function_arg/1)

    lifetimes =
      case function.lifetimes do
        [] -> ""
        lifetimes -> ["<", render_lifetimes(lifetimes), ">"]
      end

    [
      render_attrs(function.attrs),
      render_vis(function.vis),
      "fn ",
      Atom.to_string(function.name),
      lifetimes,
      "(",
      args,
      ") -> ",
      render_type(function.returns),
      " {\n",
      render_stmt_block(function.body),
      "\n}"
    ]
    |> IO.iodata_to_binary()
  end

  defp render_attrs(attrs), do: Elixir.Enum.map(attrs, &[render_attr(&1), "\n"])

  defp render_attr(%Attribute{style: :outer, path: path, args: []}),
    do: ["#[", render_attr_path(path), "]"]

  defp render_attr(%Attribute{style: :outer, path: path, args: {:value, value}}),
    do: ["#[", render_attr_path(path), " = ", render_attr_value(value), "]"]

  defp render_attr(%Attribute{style: :outer, path: path, args: args}),
    do: ["#[", render_attr_path(path), "(", render_attr_args(args), ")]"]

  defp render_attr_path(path), do: Elixir.Enum.map_join(path, "::", &to_string/1)

  defp render_attr_args(args) when is_list(args) do
    args
    |> Elixir.Enum.map(&render_attr_arg/1)
    |> Elixir.Enum.intersperse(", ")
  end

  defp render_attr_arg({key, value}), do: [to_string(key), " = ", render_attr_value(value)]
  defp render_attr_arg(%Path{} = path), do: render_expr(path)
  defp render_attr_arg(value), do: to_string(value)
  defp render_attr_value(value) when is_binary(value), do: inspect(value)
  defp render_attr_value(value), do: to_string(value)

  def render_function_arg(%FunctionArg{receiver: true, mutable: false}), do: "&self"
  def render_function_arg(%FunctionArg{receiver: true, mutable: true}), do: "&mut self"

  def render_function_arg(%FunctionArg{name: name, type: type, mutable: true}) do
    "mut #{name}: #{render_type(type)}"
  end

  def render_function_arg(%FunctionArg{name: name, type: type}) do
    "#{name}: #{render_type(type)}"
  end

  def render_function_arg({name, type}) do
    "#{name}: #{render_type(type)}"
  end

  defp render_trait(%Path{} = trait), do: render_expr(trait)
  defp render_trait(trait) when is_binary(trait), do: trait
  defp render_trait(trait), do: render_type(trait)

  defp render_lifetimes(lifetimes) do
    lifetimes
    |> Elixir.Enum.map(&["'", to_string(&1)])
    |> Elixir.Enum.intersperse(", ")
  end

  def render_struct(%Struct{} = struct) do
    derive = render_derive(struct.derive)
    vis = render_vis(struct.vis)

    lifetimes =
      case struct.lifetimes do
        [] -> ""
        values -> ["<", render_lifetimes(values), ">"]
      end

    fields = struct.fields |> Elixir.Enum.map(&render_struct_field/1) |> Elixir.Enum.join("\n")

    [
      derive,
      render_attrs(struct.attrs),
      vis,
      "struct ",
      Atom.to_string(struct.name),
      lifetimes,
      " {\n",
      fields |> indent(),
      "\n}"
    ]
    |> IO.iodata_to_binary()
  end

  def render_struct_field(%StructField{} = field) do
    [render_vis(field.vis), Atom.to_string(field.name), ": ", render_type(field.type), ","]
  end

  def render_enum(%Enum{} = enum) do
    derive = render_derive(enum.derive)
    vis = render_vis(enum.vis)
    variants = enum.variants |> Elixir.Enum.map(&render_enum_variant/1) |> Elixir.Enum.join("\n")

    [
      derive,
      render_attrs(enum.attrs),
      vis,
      "enum ",
      Atom.to_string(enum.name),
      " {\n",
      variants |> indent(),
      "\n}"
    ]
    |> IO.iodata_to_binary()
  end

  def render_enum_variant(%EnumVariant{tuple: []} = variant),
    do: [Atom.to_string(variant.name), ","]

  def render_enum_variant(%EnumVariant{} = variant) do
    [
      Atom.to_string(variant.name),
      "(",
      variant.tuple |> Elixir.Enum.map(&render_type/1) |> Elixir.Enum.intersperse(", "),
      "),"
    ]
  end

  def render_type(type) when is_binary(type), do: type
  def render_type(type) when is_atom(type), do: to_string(type)
  def render_type({:raw, source}), do: source
  def render_type(%TypeRaw{source: source}), do: source
  def render_type({:vec, inner}), do: ["Vec<", render_type(inner), ">"]
  def render_type({:option, inner}), do: ["Option<", render_type(inner), ">"]
  def render_type({:ref, inner}), do: ["&", render_type(inner)]
  def render_type({:mut_ref, inner}), do: ["&mut ", render_type(inner)]
  def render_type(%TypeUnit{}), do: "()"

  def render_type(%TypePath{parts: parts, lifetimes: lifetimes, generics: generics}) do
    base = Elixir.Enum.map_join(parts, "::", &to_string/1)

    generic_args =
      Elixir.Enum.concat(
        Elixir.Enum.map(lifetimes, &["'", to_string(&1)]),
        Elixir.Enum.map(generics, &render_type/1)
      )

    case generic_args do
      [] -> base
      args -> [base, "<", Elixir.Enum.intersperse(args, ", "), ">"]
    end
  end

  def render_type(%TypeRef{inner: inner, mutable: mutable, lifetime: lifetime}) do
    mut = if mutable, do: "mut ", else: ""
    lifetime = if lifetime, do: ["'", to_string(lifetime), " "], else: []
    ["&", lifetime, mut, render_type(inner)]
  end

  def render_type(%TypeOption{inner: inner}), do: ["Option<", render_type(inner), ">"]

  def render_type(%TypeResult{ok: ok, error: error}),
    do: ["Result<", render_type(ok), ", ", render_type(error), ">"]

  def render_type(%TypeNifResult{inner: inner}), do: ["NifResult<", render_type(inner), ">"]
  def render_type(%TypeVec{inner: inner}), do: ["Vec<", render_type(inner), ">"]
  def render_type(%TypeSlice{inner: inner}), do: ["[", render_type(inner), "]"]

  def render_type(%TypeArray{inner: inner, size: size}),
    do: ["[", render_type(inner), "; ", to_string(size), "]"]

  def render_type(%TypeTuple{items: items}) do
    rendered = Elixir.Enum.map(items, &render_type/1)
    trailing_comma = if match?([_item], items), do: ",", else: ""

    ["(", Elixir.Enum.intersperse(rendered, ", "), trailing_comma, ")"]
  end

  def render_type(%TypeBareFn{} = type) do
    lifetimes =
      if type.lifetimes == [],
        do: "",
        else: [
          "for<",
          type.lifetimes
          |> Elixir.Enum.map(&render_bound_lifetime/1)
          |> Elixir.Enum.intersperse(", "),
          "> "
        ]

    unsafe = if type.unsafe, do: "unsafe ", else: ""

    external =
      cond do
        type.external and type.abi -> ["extern ", inspect(type.abi), " "]
        type.external -> "extern "
        true -> ""
      end

    args = Elixir.Enum.map(type.args, &render_type/1)
    args = if type.variadic, do: args ++ ["..."], else: args
    returns = if type.returns, do: [" -> ", render_type(type.returns)], else: ""

    [lifetimes, unsafe, external, "fn(", Elixir.Enum.intersperse(args, ", "), ")", returns]
  end

  def render_type(%TypeImplTrait{bounds: bounds}),
    do: ["impl ", Elixir.Enum.intersperse(bounds, " + ")]

  defp render_bound_lifetime(lifetime) when is_atom(lifetime), do: ["'", to_string(lifetime)]
  defp render_bound_lifetime("'" <> _rest = lifetime), do: lifetime
  defp render_bound_lifetime(lifetime) when is_binary(lifetime), do: ["'", lifetime]

  def render_stmt(%Let{} = stmt) do
    mut = if stmt.mutable, do: "mut ", else: ""
    type = if stmt.type, do: [": ", render_type(stmt.type)], else: []
    ["let ", mut, render_pattern(stmt.pattern), type, " = ", render_expr(stmt.expr), ";"]
  end

  def render_stmt(%LetElse{} = stmt) do
    [
      "let ",
      render_pattern(stmt.pattern),
      " = ",
      render_expr(stmt.expr),
      " else {\n",
      render_stmt_block(stmt.else),
      "\n};"
    ]
  end

  def render_stmt(%Assign{} = stmt),
    do: [render_expr(stmt.target), " = ", render_expr(stmt.expr), ";"]

  def render_stmt(%AssignOp{} = stmt),
    do: [
      render_expr(stmt.target),
      " ",
      render_assign_op(stmt.op),
      "= ",
      render_expr(stmt.expr),
      ";"
    ]

  def render_stmt(%ExprStmt{} = stmt), do: [render_expr(stmt.expr), ";"]
  def render_stmt(%Return{} = stmt), do: render_expr(stmt.expr)
  def render_stmt(%EarlyReturn{} = stmt), do: ["return ", render_expr(stmt.expr), ";"]

  def render_stmt(%IfLet{} = stmt) do
    else_part =
      if stmt.else == [], do: [], else: [" else {\n", render_stmt_block(stmt.else), "\n}"]

    [
      "if let ",
      render_pattern(stmt.pattern),
      " = ",
      render_expr(stmt.expr),
      " {\n",
      render_stmt_block(stmt.then),
      "\n}",
      else_part
    ]
  end

  def render_stmt(%For{} = stmt) do
    [
      "for ",
      render_pattern(stmt.pattern),
      " in ",
      render_expr(stmt.expr),
      " {\n",
      render_stmt_block(stmt.body),
      "\n}"
    ]
  end

  def render_stmt(%Loop{} = stmt), do: ["loop {\n", render_stmt_block(stmt.body), "\n}"]
  def render_stmt(%Break{expr: nil}), do: "break;"
  def render_stmt(%Break{expr: expr}), do: ["break ", render_expr(expr), ";"]
  def render_stmt(%Continue{}), do: "continue;"

  def render_expr(%Var{name: name}), do: Atom.to_string(name)
  def render_expr(%Path{parts: parts}), do: Elixir.Enum.map_join(parts, "::", &render_path_part/1)

  def render_expr(%Field{receiver: receiver, field: field}),
    do: [render_expr(receiver), ".", to_string(field)]

  def render_expr(%Index{receiver: receiver, index: index}),
    do: [render_expr(receiver), "[", render_expr(index), "]"]

  def render_expr(%Range{start: start, stop: stop, inclusive: inclusive}),
    do: [
      if(start, do: render_expr(start), else: []),
      if(inclusive, do: "..=", else: ".."),
      if(stop, do: render_expr(stop), else: [])
    ]

  def render_expr(%Cast{expr: expr, type: type}),
    do: [render_cast_operand(expr), " as ", render_type(type)]

  def render_expr(%UnaryOp{op: op, expr: expr}), do: [render_unary_op(op), render_expr(expr)]

  def render_expr(%PathCall{path: path, args: args, generics: generics}) do
    [render_expr(path), render_generics(generics), "(", render_args(args), ")"]
  end

  def render_expr(%MethodCall{receiver: receiver, method: method, args: args, generics: generics}) do
    [
      render_method_receiver(receiver),
      ".",
      to_string(method),
      render_generics(generics),
      "(",
      render_args(args),
      ")"
    ]
  end

  def render_expr(%LocalCall{name: name, args: args}),
    do: [to_string(name), "(", render_args(args), ")"]

  def render_expr(%StructLiteral{path: path, fields: fields}) do
    rendered_fields =
      fields
      |> Elixir.Enum.map(fn {name, expr} -> [to_string(name), ": ", render_expr(expr)] end)
      |> Elixir.Enum.intersperse(", ")

    [render_expr(path), " { ", rendered_fields, " }"]
  end

  def render_expr(%Ref{expr: expr, mutable: false}), do: ["&", render_expr(expr)]
  def render_expr(%Ref{expr: expr, mutable: true}), do: ["&mut ", render_expr(expr)]
  def render_expr(%Try{expr: expr}), do: [render_expr(expr), "?"]
  def render_expr(%Tuple{values: values}), do: ["(", render_args(values), ")"]
  def render_expr(%VecLiteral{values: values}), do: ["vec![", render_args(values), "]"]
  def render_expr(%ArrayLiteral{values: values}), do: ["[", render_args(values), "]"]

  def render_expr(%MacroRepeatExpr{expr: expr, separator: separator, operator: operator}) do
    ["$(", render_expr(expr), separator, ")", operator]
  end

  def render_expr(%Closure{args: args, body: body}) do
    ["|", Elixir.Enum.map_join(args, ", ", &to_string/1), "| ", render_expr(body)]
  end

  def render_expr(%Literal{value: value}) when is_binary(value), do: inspect(value)

  def render_expr(%ByteString{value: value}), do: ["b", inspect(value)]

  def render_expr(%EscapeExpr{source: source}), do: source

  def render_expr(%Literal{value: value}) when is_integer(value) or is_float(value),
    do: to_string(value)

  def render_expr(%Literal{value: true}), do: "true"
  def render_expr(%Literal{value: false}), do: "false"

  def render_expr(%TokenMacro{path: path, tokens: tokens}),
    do: [render_expr(path), "!(", tokens, ")"]

  def render_expr(%MacroCall{path: path, args: args}),
    do: [render_expr(path), "!(", render_args(args), ")"]

  def render_expr(%AtomValue{name: name, module: module}) do
    [Elixir.Enum.map_join(module, "::", &to_string/1), "::", Atom.to_string(name), "()"]
  end

  def render_expr(%None{}), do: "None"
  def render_expr(%Some{expr: expr}), do: ["Some(", render_expr(expr), ")"]
  def render_expr(%Ok{expr: nil}), do: "Ok(())"
  def render_expr(%Ok{expr: expr}), do: ["Ok(", render_expr(expr), ")"]
  def render_expr(%Err{expr: expr}), do: ["Err(", render_expr(expr), ")"]

  def render_expr(%NifRaiseAtom{name: name}) do
    ~s|rustler::Error::RaiseAtom("#{name}")|
  end

  def render_expr(%BlockExpr{} = block), do: ["{\n", render_stmt_block(block.body), "\n}"]

  def render_expr(%Match{} = match) do
    arms = match.arms |> Elixir.Enum.map(&render_arm/1) |> Elixir.Enum.join("\n")
    ["match ", render_expr(match.expr), " {\n", indent(arms), "\n}"]
  end

  def render_expr(%If{else: []} = if_expr) do
    [
      "if ",
      render_expr(if_expr.condition),
      " {\n",
      render_stmt_block(if_expr.then),
      "\n}"
    ]
  end

  def render_expr(%If{} = if_expr) do
    [
      "if ",
      render_expr(if_expr.condition),
      " {\n",
      render_stmt_block(if_expr.then),
      "\n} else {\n",
      render_stmt_block(if_expr.else),
      "\n}"
    ]
  end

  def render_expr(%BinaryOp{left: left, op: op, right: right}) do
    [render_expr(left), " ", render_binary_op(op), " ", render_expr(right)]
  end

  def render_arm(%Arm{pattern: pattern, guard: guard, body: body}) do
    [
      render_pattern(pattern),
      render_arm_guard(guard),
      " => {\n",
      render_stmt_block(body),
      "\n},"
    ]
  end

  defp render_arm_guard(nil), do: []
  defp render_arm_guard(guard), do: [" if ", render_expr(guard)]

  def render_pattern(%PatVar{name: name, mutable: true}), do: ["mut ", Atom.to_string(name)]
  def render_pattern(%PatVar{name: name}), do: Atom.to_string(name)
  def render_pattern(%PatWildcard{}), do: "_"
  def render_pattern(%PatPath{path: path}), do: render_expr(path)
  def render_pattern(%PatLiteral{value: value}) when is_binary(value), do: inspect(value)

  def render_pattern(%PatLiteral{value: value}) when is_integer(value),
    do: Integer.to_string(value)

  def render_pattern(%PatLiteral{value: value}) when is_atom(value), do: Atom.to_string(value)
  def render_pattern(%PatNone{}), do: "None"
  def render_pattern(%PatSome{pattern: pattern}), do: ["Some(", render_pattern(pattern), ")"]
  def render_pattern(%PatOk{pattern: pattern}), do: ["Ok(", render_pattern(pattern), ")"]
  def render_pattern(%PatErr{pattern: pattern}), do: ["Err(", render_pattern(pattern), ")"]

  def render_pattern(%PatPathTuple{path: path, patterns: patterns}) do
    [
      render_expr(path),
      "(",
      patterns |> Elixir.Enum.map(&render_pattern/1) |> Elixir.Enum.intersperse(", "),
      ")"
    ]
  end

  def render_pattern(%PatStruct{path: path, fields: fields}) do
    rendered_fields =
      fields
      |> Elixir.Enum.map(fn {name, pattern} ->
        [to_string(name), ": ", render_pattern(pattern)]
      end)
      |> Elixir.Enum.intersperse(", ")

    [render_expr(path), " { ", rendered_fields, " }"]
  end

  def render_pattern(%PatSlice{patterns: patterns, rest: rest}) do
    entries =
      patterns
      |> Elixir.Enum.reduce([], &[render_pattern(&1) | &2])
      |> then(&if(rest, do: [[render_pattern(rest), " @ .."] | &1], else: &1))
      |> Elixir.Enum.reverse()

    ["[", Elixir.Enum.intersperse(entries, ", "), "]"]
  end

  def render_pattern(%PatAtomGuard{name: name, module: module}),
    do: [
      "value if value == ",
      Elixir.Enum.map_join(module, "::", &to_string/1),
      "::",
      Atom.to_string(name),
      "()"
    ]

  def render_pattern(%PatTuple{patterns: patterns}) do
    ["(", patterns |> Elixir.Enum.map(&render_pattern/1) |> Elixir.Enum.intersperse(", "), ")"]
  end

  defp render_args(args),
    do: args |> Elixir.Enum.map(&render_expr/1) |> Elixir.Enum.intersperse(", ")

  defp render_generics([]), do: []

  defp render_generics(generics),
    do: ["::<", generics |> Elixir.Enum.map(&render_type/1) |> Elixir.Enum.intersperse(", "), ">"]

  @rust_keywords MapSet.new(~w[
                   as async await break const continue crate dyn else enum extern false fn for if impl
                   in let loop match mod move mut pub ref return self Self static struct super trait true
                   type unsafe use where while
                 ]a)

  defp render_path_part(nil), do: "nil"

  defp render_path_part(part) when is_atom(part) do
    name = Atom.to_string(part)

    if MapSet.member?(@rust_keywords, part) do
      "r#" <> name
    else
      name
    end
  end

  defp render_path_part(part), do: to_string(part)

  defp render_assign_op(:add), do: "+"
  defp render_assign_op(:sub), do: "-"
  defp render_assign_op(:mul), do: "*"
  defp render_assign_op(:div), do: "/"
  defp render_assign_op(:shr), do: ">>"
  defp render_assign_op(:bitand), do: "&"

  defp render_binary_op(:eq), do: "=="
  defp render_binary_op(:ne), do: "!="
  defp render_binary_op(:lt), do: "<"
  defp render_binary_op(:lte), do: "<="
  defp render_binary_op(:gt), do: ">"
  defp render_binary_op(:gte), do: ">="
  defp render_binary_op(:add), do: "+"
  defp render_binary_op(:sub), do: "-"
  defp render_binary_op(:mul), do: "*"
  defp render_binary_op(:div), do: "/"
  defp render_binary_op(:rem), do: "%"
  defp render_binary_op(:and), do: "&&"
  defp render_binary_op(:or), do: "||"
  defp render_binary_op(:shr), do: ">>"
  defp render_binary_op(:bitand), do: "&"

  defp render_method_receiver(%BinaryOp{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_method_receiver(%Cast{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_method_receiver(%Match{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_method_receiver(%If{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_method_receiver(expr), do: render_expr(expr)

  defp render_cast_operand(%BinaryOp{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_cast_operand(%If{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_cast_operand(%Match{} = expr), do: ["(", render_expr(expr), ")"]
  defp render_cast_operand(expr), do: render_expr(expr)

  defp render_use_group_member({base, names}) when is_list(names) do
    [
      to_string(base),
      "::{",
      names |> Elixir.Enum.map(&render_use_group_member/1) |> Elixir.Enum.intersperse(", "),
      "}"
    ]
  end

  defp render_use_group_member(:self), do: "self"
  defp render_use_group_member(:*), do: "*"
  defp render_use_group_member(value), do: to_string(value)

  defp render_unary_op(:not), do: "!"
  defp render_unary_op(:neg), do: "-"
  defp render_unary_op(:deref), do: "*"

  defp render_derive([]), do: []

  defp render_derive(values) do
    [
      "#[derive(",
      values |> Elixir.Enum.flat_map(&derive_paths/1) |> Elixir.Enum.intersperse(", "),
      ")]\n"
    ]
  end

  defp derive_paths(%Derive{paths: paths}), do: Elixir.Enum.map(paths, &derive_path/1)
  defp derive_paths(value), do: [derive_path(value)]

  defp derive_path(parts) when is_list(parts), do: Elixir.Enum.map_join(parts, "::", &to_string/1)
  defp derive_path(value), do: to_string(value)

  defp render_vis(:pub), do: "pub "
  defp render_vis(:crate), do: "pub(crate) "
  defp render_vis(nil), do: []

  defp render_stmt_lines(statements),
    do: statements |> Elixir.Enum.map(&render_stmt/1) |> Elixir.Enum.join("\n")

  defp render_stmt_block(statements), do: statements |> render_stmt_lines() |> indent()

  defp indent(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Elixir.Enum.map_join("\n", &("    " <> &1))
  end
end
