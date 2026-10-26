defmodule RustQ.Meta.Lower.Collection do
  @moduledoc """
  Keyed collections, `HashMap`, `BTreeMap`, `HashSet`, and `BTreeSet`, as `RustQ.Meta.Lower.Map`
  and `RustQ.Meta.Lower.MapSet` lower them.

  Elixir never changes a collection, so a function returning an updated one takes it only
  where nothing uses it afterwards, and otherwise updates a copy:

      { let mut rustq_updated = scores; rustq_updated.insert(name, 1); rustq_updated }
  """

  import RustQ.Meta.Lower.Stdlib.Lowering, only: [lowered: 2, lowered: 3, type_of: 2, in_use?: 2]

  alias RustQ.Meta.Lower.Stdlib.Lowering.Context
  alias RustQ.Meta.Type
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A

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
  def keyed_of(collection, %Context{} = context), do: keyed(type_of(collection, context))

  @doc """
  An update of `collection`: `statements` receives the variable holding the collection, or a
  copy of it when `collection` is still in use, and the block returns that variable.
  """
  @spec updated(Macro.t(), (AST.expr() -> [AST.stmt()]), Context.t()) :: AST.expr()
  def updated(collection, statements, %Context{} = context) do
    name = :rustq_updated
    variable = A.var(name)

    A.block_expr(
      [
        %AST.Let{
          pattern: %AST.PatVar{name: name},
          expr: owned(collection, context),
          mutable: true
        }
      ] ++
        statements.(variable) ++ [A.return_stmt(variable)]
    )
  end

  @doc "`collection` to take: itself at its last use, otherwise a copy."
  @spec owned(Macro.t(), Context.t()) :: AST.expr()
  def owned(collection, %Context{} = context) do
    lowered = lowered(collection, context)
    type = type_of(collection, context)

    cond do
      borrowed?(type) -> A.method(lowered, :clone)
      in_use?(collection, context) and not copy?(type) -> A.method(lowered, :clone)
      true -> lowered
    end
  end

  # A value behind a reference is never owned: taking it copies what it refers to.
  defp borrowed?(%Type{kind: kind}) when kind in [:ref, :mut_ref, :slice], do: true
  defp borrowed?(_type), do: false

  @doc "A key or item passed by reference, borrowed unless it already is one."
  @spec borrowed(Macro.t(), Type.t(), Context.t()) :: AST.expr()
  def borrowed(expression, %Type{} = type, %Context{} = context),
    do: lowered(expression, Type.ref(type), context)

  @doc "A value read out of a collection: copied when that costs nothing, otherwise cloned."
  @spec read_out(AST.expr(), Type.t()) :: AST.expr()
  def read_out(option, %Type{} = type) do
    method = if copy?(type), do: :copied, else: :cloned
    A.method(option, method)
  end

  @doc """
  Whether a value is copied as cheaply as it is borrowed: a number, atom, reference, or tuple
  of them.
  """
  @spec copy?(Type.t() | nil) :: boolean()
  def copy?(%Type{kind: kind}) when kind in [:ref], do: true
  def copy?(%Type{kind: :alias, meta: %{target: %Type{} = target}}), do: copy?(target)

  def copy?(%Type{} = type) do
    case Type.category(type) do
      category when category in [:integer, :number, :boolean, :atom] -> true
      {:tuple, elements} -> Enum.all?(elements, &copy?/1)
      _other -> false
    end
  end

  def copy?(_type), do: false
end
