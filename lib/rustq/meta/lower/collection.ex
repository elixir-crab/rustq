defmodule RustQ.Meta.Lower.Collection do
  @moduledoc """
  Keyed collections, `HashMap`, `BTreeMap`, `HashSet`, and `BTreeSet`, as `RustQ.Meta.Lower.Map`
  and `RustQ.Meta.Lower.MapSet` lower them.

  Elixir never changes a collection, so a function returning an updated one takes it only
  where nothing uses it afterwards, and otherwise updates a copy:

      { let mut rustq_updated = scores; rustq_updated.insert(name, 1); rustq_updated }
  """

  alias RustQ.Meta.Lower.Stdlib.Context
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST

  @maps [:HashMap, :BTreeMap]
  @sets [:HashSet, :BTreeSet]

  @type keyed :: {:map, Type.t(), Type.t()} | {:set, Type.t()}

  @doc "The keyed collection a type is, or is a reference to, with its key and value types."
  @spec keyed(Type.t() | nil) :: keyed() | nil
  def keyed(%Type{kind: kind} = type) when kind in [:ref, :mut_ref],
    do: type |> Type.ref_inner() |> keyed()

  def keyed(%Type{kind: :alias, meta: %{target: %Type{} = target}}), do: keyed(target)

  def keyed(%Type{ast: %AST.TypePath{parts: parts, generics: [key, value]}}) do
    if List.last(parts) in @maps, do: {:map, Type.ast_type(key), Type.ast_type(value)}
  end

  def keyed(%Type{ast: %AST.TypePath{parts: parts, generics: [item]}}) do
    if List.last(parts) in @sets, do: {:set, Type.ast_type(item)}
  end

  def keyed(_type), do: nil

  @doc "The type of a `HashMap` from `key` to `value`."
  @spec map(Type.t(), Type.t()) :: Type.t()
  def map(%Type{} = key, %Type{} = value), do: path_type(:HashMap, [key.ast, value.ast])

  @doc "The type of a `HashSet` of `item`."
  @spec set(Type.t()) :: Type.t()
  def set(%Type{} = item), do: path_type(:HashSet, [item.ast])

  defp path_type(collection, generics) do
    ast = %AST.TypePath{parts: [collection], generics: generics}
    %Type{kind: :type, rust: RustQ.Rust.render_type(ast), ast: ast, meta: %{}}
  end

  @doc "The keyed collection `collection` is, by its type."
  @spec keyed_of(Macro.t(), Context.t()) :: keyed() | nil
  def keyed_of(collection, %Context{} = context), do: keyed(context.type_of.(collection))

  @doc """
  An update of `collection`: `statements` receives the variable holding the collection, or a
  copy of it when `collection` is still in use, and the block returns that variable.
  """
  @spec updated(Macro.t(), [Macro.t()], (AST.expr() -> [AST.stmt()]), Context.t()) :: AST.expr()
  def updated(collection, others, statements, %Context{} = context) do
    name = :rustq_updated
    variable = %AST.Var{name: name}

    %AST.BlockExpr{
      body:
        [
          %AST.Let{
            pattern: %AST.PatVar{name: name},
            expr: owned(collection, others, context),
            mutable: true
          }
        ] ++
          statements.(variable) ++ [%AST.Return{expr: variable}]
    }
  end

  @doc "`collection` to take: itself at its last use, otherwise a copy."
  @spec owned(Macro.t(), [Macro.t()], Context.t()) :: AST.expr()
  def owned(collection, others, %Context{} = context) do
    lowered = context.lower.(collection)

    if context.in_use?.(collection, others),
      do: %AST.MethodCall{receiver: lowered, method: :clone, args: []},
      else: lowered
  end

  @doc "A key or item passed by reference, borrowed unless it already is one."
  @spec borrowed(Macro.t(), Type.t(), Context.t()) :: AST.expr()
  def borrowed(expression, %Type{} = type, %Context{} = context),
    do: context.lower_expected.(expression, Type.ref(type))

  @doc "A value read out of a collection: copied when that costs nothing, otherwise cloned."
  @spec read_out(AST.expr(), Type.t()) :: AST.expr()
  def read_out(option, %Type{} = type) do
    method = if copy?(type), do: :copied, else: :cloned
    %AST.MethodCall{receiver: option, method: method, args: []}
  end

  @doc "Whether a value is copied as cheaply as it is borrowed: a number, atom, or reference."
  @spec copy?(Type.t() | nil) :: boolean()
  def copy?(%Type{kind: kind}) when kind in [:ref], do: true
  def copy?(%Type{} = type), do: Type.category(type) in [:integer, :number, :boolean, :atom]
  def copy?(_type), do: false

  @doc "A call on `receiver`."
  @spec call(AST.expr(), atom(), [AST.expr()]) :: AST.expr()
  def call(receiver, method, args \\ []),
    do: %AST.MethodCall{receiver: receiver, method: method, args: args}

  @doc "A statement calling `method` on `receiver`."
  @spec statement(AST.expr(), atom(), [AST.expr()]) :: AST.stmt()
  def statement(receiver, method, args), do: %AST.ExprStmt{expr: call(receiver, method, args)}
end
