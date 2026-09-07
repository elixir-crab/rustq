defmodule RustQ.Rust.AST do
  @moduledoc """
  Small Rust AST/IR used by macro frontends before final RustQ validation.

  This is intentionally much smaller than Rust's full grammar. It captures the
  Rust-shaped nodes that `RustQ.Meta.defrust/2` can produce from valid Elixir
  AST, then renders them only at the final fragment-validation boundary.
  """

  alias __MODULE__, as: AST

  alias __MODULE__.{
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
    Loop,
    LocalCall,
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
    TypeRef,
    TypeResult,
    TypeSlice,
    TypeTuple,
    TypeUnit,
    TypeVec,
    UnaryOp,
    UnsafeBlock,
    Use,
    Var,
    VecLiteral
  }

  @typedoc "Rust item nodes supported by RustQ's compact AST."
  @type item ::
          Use.t()
          | Module.t()
          | Const.t()
          | Static.t()
          | TypeAlias.t()
          | MacroItem.t()
          | MacroItemCall.t()
          | MacroRules.t()
          | Impl.t()
          | Function.t()
          | Struct.t()
          | Enum.t()

  @typedoc "Rust statement nodes supported by RustQ's compact AST."
  @type stmt ::
          Let.t()
          | LetElse.t()
          | Assign.t()
          | AssignOp.t()
          | ExprStmt.t()
          | Return.t()
          | EarlyReturn.t()
          | IfLet.t()
          | For.t()
          | Loop.t()
          | Break.t()
          | Continue.t()

  @typedoc "Rust expression nodes supported by RustQ's compact AST."
  @type expr ::
          Var.t()
          | Path.t()
          | Field.t()
          | Index.t()
          | Range.t()
          | Cast.t()
          | UnaryOp.t()
          | PathCall.t()
          | MethodCall.t()
          | StructLiteral.t()
          | LocalCall.t()
          | Ref.t()
          | Try.t()
          | Tuple.t()
          | VecLiteral.t()
          | ArrayLiteral.t()
          | MacroRepeatExpr.t()
          | Closure.t()
          | Literal.t()
          | ByteString.t()
          | EscapeExpr.t()
          | TokenMacro.t()
          | MacroCall.t()
          | AtomValue.t()
          | None.t()
          | Some.t()
          | Ok.t()
          | Err.t()
          | NifRaiseAtom.t()
          | BlockExpr.t()
          | UnsafeBlock.t()
          | Match.t()
          | If.t()
          | BinaryOp.t()

  @typedoc "Rust type nodes supported by RustQ's compact AST."
  @type type ::
          TypePath.t()
          | TypeRef.t()
          | TypeOption.t()
          | TypeResult.t()
          | TypeNifResult.t()
          | TypeVec.t()
          | TypeSlice.t()
          | TypeArray.t()
          | TypeTuple.t()
          | TypeBareFn.t()
          | TypeImplTrait.t()
          | RustQ.Rust.AST.TypeRaw.t()
          | TypeUnit.t()

  @typedoc "Rust pattern nodes supported by RustQ's compact AST."
  @type pat ::
          PatVar.t()
          | PatWildcard.t()
          | PatPath.t()
          | PatLiteral.t()
          | PatNone.t()
          | PatSome.t()
          | PatAtomGuard.t()
          | PatTuple.t()
          | PatOk.t()
          | PatErr.t()
          | PatPathTuple.t()
          | PatStruct.t()
          | PatSlice.t()

  @type vis :: :pub | :crate | nil

  import RustQ.Rust.AST.NodeDSL

  defnode(Use, :item, [tree: nil, parts: nil, group: nil],
    type:
      quote(
        do: %__MODULE__{
          tree: String.t() | nil,
          parts: [atom() | String.t()] | nil,
          group: {[atom() | String.t()], [atom() | String.t()]} | nil
        }
      )
  )

  defnode(Attribute, :field, [:path, args: [], style: :outer],
    type:
      quote(
        do: %__MODULE__{
          path: [atom() | String.t()],
          args:
            keyword()
            | [atom() | String.t() | AST.Path.t()]
            | {:value, String.t() | atom()},
          style: :outer | :inner
        }
      )
  )

  defnode(Module, :item, [:name, items: [], vis: nil],
    type: quote(do: %__MODULE__{name: atom(), items: [AST.item()], vis: AST.vis()})
  )

  defnode(Const, :item, [:name, :type, :expr, vis: nil],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          type: AST.type(),
          expr: AST.expr(),
          vis: AST.vis()
        }
      )
  )

  defnode(Static, :item, [:name, :type, :expr, mutable: false, vis: nil],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          type: AST.type(),
          expr: AST.expr(),
          mutable: boolean(),
          vis: AST.vis()
        }
      )
  )

  defnode(TypeAlias, :item, [:name, :type, vis: nil],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          type: AST.type(),
          vis: AST.vis()
        }
      )
  )

  defnode(MacroItem, :item, [:source], type: quote(do: %__MODULE__{source: String.t()}))

  @type macro_token ::
          String.t()
          | atom()
          | Literal.t()
          | Path.t()
          | MacroVar.t()
          | MacroCapture.t()
          | MacroRepeat.t()

  defnode(MacroVar, :field, [:name, :fragment],
    type: quote(do: %__MODULE__{name: atom(), fragment: atom()})
  )

  defnode(MacroCapture, :field, [:name], type: quote(do: %__MODULE__{name: atom()}))

  defnode(MacroRepeat, :field, [tokens: [], separator: nil, operator: :*],
    type:
      quote(
        do: %__MODULE__{
          tokens: [AST.macro_token()],
          separator: String.t() | nil,
          operator: :* | :+ | :"?"
        }
      )
  )

  defnode(MacroRule, :field, [pattern: [], expansion: []],
    type: quote(do: %__MODULE__{pattern: [AST.macro_token()], expansion: [AST.macro_token()]})
  )

  defnode(MacroRules, :item, [:name, rules: [], attrs: []],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          rules: [MacroRule.t()],
          attrs: [AST.Attribute.t()]
        }
      )
  )

  defnode(MacroItemCall, :item, [:path, args: [], tokens: nil],
    type:
      quote(
        do: %__MODULE__{
          path: Path.t(),
          args: [atom() | String.t() | {atom() | String.t(), String.t()}],
          tokens: [AST.macro_token()] | nil
        }
      )
  )

  defnode(Impl, :item, [:target, trait: nil, items: [], attrs: [], lifetimes: []],
    type:
      quote(
        do: %__MODULE__{
          target: AST.type(),
          trait: AST.type() | nil,
          items: [AST.item()],
          attrs: [Attribute.t()],
          lifetimes: [atom()]
        }
      )
  )

  defnode(FunctionArg, :field, [:name, :type, receiver: false, mutable: false],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          type: AST.type() | nil,
          receiver: boolean(),
          mutable: boolean()
        }
      )
  )

  defnode(
    Function,
    :item,
    [:name, args: [], returns: nil, body: [], lifetimes: [], vis: nil, attrs: []],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          args: [FunctionArg.t()],
          returns: AST.type(),
          body: [AST.stmt()],
          lifetimes: [atom()],
          vis: AST.vis(),
          attrs: [Attribute.t()]
        }
      )
  )

  defnode(Derive, :field, [:paths],
    type: quote(do: %__MODULE__{paths: [[atom() | String.t()] | atom() | String.t()]})
  )

  defnode(Struct, :item, [:name, fields: [], vis: nil, derive: [], lifetimes: [], attrs: []],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          fields: [StructField.t()],
          vis: AST.vis(),
          derive: [Derive.t() | atom()],
          lifetimes: [atom()],
          attrs: [Attribute.t()]
        }
      )
  )

  defnode(StructField, :field, [:name, :type, vis: nil],
    type: quote(do: %__MODULE__{name: atom(), type: AST.type(), vis: AST.vis()})
  )

  defnode(Enum, :item, [:name, variants: [], vis: nil, derive: [], attrs: []],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          variants: [EnumVariant.t()],
          vis: AST.vis(),
          derive: [Derive.t() | atom()],
          attrs: [Attribute.t()]
        }
      )
  )

  defnode(EnumVariant, :field, [:name, tuple: [], fields: [], attrs: []],
    type:
      quote(
        do: %__MODULE__{
          name: atom(),
          tuple: [AST.type()],
          fields: [AST.StructField.t()],
          attrs: [AST.Attribute.t()]
        }
      )
  )

  defnode(TypePath, :type, [:parts, lifetimes: [], generics: []],
    type:
      quote(
        do: %__MODULE__{
          parts: [atom() | String.t()],
          lifetimes: [atom()],
          generics: [AST.type()]
        }
      )
  )

  defnode(TypeRef, :type, [:inner, mutable: false, lifetime: nil],
    type: quote(do: %__MODULE__{inner: AST.type(), mutable: boolean(), lifetime: atom() | nil})
  )

  defnode(TypeOption, :type, [:inner], type: quote(do: %__MODULE__{inner: AST.type()}))

  defnode(TypeResult, :type, [:ok, :error],
    type: quote(do: %__MODULE__{ok: AST.type(), error: AST.type()})
  )

  defnode(TypeNifResult, :type, [:inner], type: quote(do: %__MODULE__{inner: AST.type()}))

  defnode(TypeVec, :type, [:inner], type: quote(do: %__MODULE__{inner: AST.type()}))

  defnode(TypeSlice, :type, [:inner], type: quote(do: %__MODULE__{inner: AST.type()}))

  defnode(TypeArray, :type, [:inner, :size],
    type: quote(do: %__MODULE__{inner: AST.type(), size: String.t() | integer()})
  )

  defnode(TypeTuple, :type, [items: []], type: quote(do: %__MODULE__{items: [AST.type()]}))

  defnode(
    TypeBareFn,
    :type,
    [
      args: [],
      returns: nil,
      lifetimes: [],
      unsafe: false,
      external: false,
      abi: nil,
      variadic: false
    ],
    type:
      quote(
        do: %__MODULE__{
          args: [AST.type()],
          returns: AST.type() | nil,
          lifetimes: [atom() | String.t()],
          unsafe: boolean(),
          external: boolean(),
          abi: String.t() | nil,
          variadic: boolean()
        }
      )
  )

  defnode(TypeImplTrait, :type, [bounds: [], callable: nil, kind: :fn, traits: [], lifetime: nil],
    type:
      quote(
        do: %__MODULE__{
          bounds: [String.t()],
          callable: TypeBareFn.t() | nil,
          kind: :fn | :fn_mut | :fn_once,
          traits: [TypePath.t()],
          lifetime: atom() | nil
        }
      )
  )

  defnode(TypeRaw, :type, [:source], type: quote(do: %__MODULE__{source: String.t()}))

  defnode(TypeUnit, :type, [], type: quote(do: %__MODULE__{}))

  defnode(Let, :stmt, [:pattern, :expr, mutable: false, type: nil],
    type:
      quote(
        do: %__MODULE__{
          pattern: AST.pat(),
          expr: AST.expr(),
          mutable: boolean(),
          type: AST.type() | nil
        }
      )
  )

  defnode(LetElse, :stmt, [:pattern, :expr, else: []],
    type:
      quote(
        do: %__MODULE__{
          pattern: AST.pat(),
          expr: AST.expr(),
          else: [AST.stmt()]
        }
      )
  )

  defnode(Assign, :stmt, [:target, :expr],
    type: quote(do: %__MODULE__{target: AST.expr(), expr: AST.expr()})
  )

  defnode(AssignOp, :stmt, [:target, :op, :expr],
    type: quote(do: %__MODULE__{target: AST.expr(), op: atom(), expr: AST.expr()})
  )

  defnode(ExprStmt, :stmt, [:expr], type: quote(do: %__MODULE__{expr: AST.expr()}))

  defnode(Return, :stmt, [:expr], type: quote(do: %__MODULE__{expr: AST.expr()}))

  defnode(EarlyReturn, :stmt, [:expr], type: quote(do: %__MODULE__{expr: AST.expr()}))

  defnode(IfLet, :stmt, [:pattern, :expr, then: [], else: []],
    type:
      quote(
        do: %__MODULE__{
          pattern: AST.pat(),
          expr: AST.expr(),
          then: [AST.stmt()],
          else: [AST.stmt()]
        }
      )
  )

  defnode(For, :stmt, [:pattern, :expr, body: []],
    type:
      quote(
        do: %__MODULE__{
          pattern: AST.pat(),
          expr: AST.expr(),
          body: [AST.stmt()]
        }
      )
  )

  defnode(Loop, :stmt, [body: []], type: quote(do: %__MODULE__{body: [AST.stmt()]}))

  defnode(Break, :stmt, [:expr], type: quote(do: %__MODULE__{expr: AST.expr() | nil}))

  defnode(Continue, :stmt, [], type: quote(do: %__MODULE__{}))

  defnode(Var, :expr, [:name], type: quote(do: %__MODULE__{name: atom()}))

  defnode(Path, :expr, [:parts], type: quote(do: %__MODULE__{parts: [atom() | String.t()]}))

  defnode(Field, :expr, [:receiver, :field],
    type: quote(do: %__MODULE__{receiver: AST.expr(), field: atom() | integer()})
  )

  defnode(Index, :expr, [:receiver, :index],
    type: quote(do: %__MODULE__{receiver: AST.expr(), index: AST.expr()})
  )

  defnode(Range, :expr, [:start, :stop, inclusive: false],
    type:
      quote(
        do: %__MODULE__{
          start: AST.expr() | nil,
          stop: AST.expr() | nil,
          inclusive: boolean()
        }
      )
  )

  defnode(Cast, :expr, [:expr, :type],
    type: quote(do: %__MODULE__{expr: AST.expr(), type: AST.type()})
  )

  defnode(UnaryOp, :expr, [:op, :expr],
    type: quote(do: %__MODULE__{op: atom(), expr: AST.expr()})
  )

  defnode(PathCall, :expr, [:path, args: [], generics: []],
    type:
      quote(
        do: %__MODULE__{
          path: Path.t(),
          args: [AST.expr()],
          generics: [AST.type()]
        }
      )
  )

  defnode(MethodCall, :expr, [:receiver, :method, args: [], generics: []],
    type:
      quote(
        do: %__MODULE__{
          receiver: AST.expr(),
          method: atom(),
          args: [AST.expr()],
          generics: [AST.type()]
        }
      )
  )

  defnode(StructLiteral, :expr, [:path, fields: []],
    type: quote(do: %__MODULE__{path: Path.t(), fields: [{atom(), AST.expr()}]})
  )

  defnode(LocalCall, :expr, [:name, args: []],
    type: quote(do: %__MODULE__{name: atom(), args: [AST.expr()]})
  )

  defnode(Ref, :expr, [:expr, mutable: false],
    type: quote(do: %__MODULE__{expr: AST.expr(), mutable: boolean()})
  )

  defnode(Try, :expr, [:expr], type: quote(do: %__MODULE__{expr: AST.expr()}))

  defnode(Tuple, :expr, [:values], type: quote(do: %__MODULE__{values: [AST.expr()]}))

  defnode(VecLiteral, :expr, [:values], type: quote(do: %__MODULE__{values: [AST.expr()]}))

  defnode(ArrayLiteral, :expr, [:values], type: quote(do: %__MODULE__{values: [AST.expr()]}))

  defnode(MacroRepeatExpr, :expr, [:expr, separator: ",", operator: "*"],
    type: quote(do: %__MODULE__{expr: AST.expr(), separator: String.t(), operator: String.t()})
  )

  defnode(Closure, :expr, [:args, :body, move: false],
    type:
      quote(
        do: %__MODULE__{
          args: [atom() | AST.pat() | {AST.pat(), AST.type()}],
          body: AST.expr(),
          move: boolean()
        }
      )
  )

  defnode(Literal, :expr, [:value],
    type: quote(do: %__MODULE__{value: String.t() | integer() | float() | boolean()})
  )

  defnode(ByteString, :expr, [:value], type: quote(do: %__MODULE__{value: String.t()}))

  defnode(EscapeExpr, :expr, [:source], type: quote(do: %__MODULE__{source: String.t()}))

  defnode(TokenMacro, :expr, [:path, :tokens],
    type: quote(do: %__MODULE__{path: Path.t(), tokens: String.t()})
  )

  defnode(MacroCall, :expr, [:path, args: []],
    type: quote(do: %__MODULE__{path: Path.t(), args: [AST.expr()]})
  )

  defnode(AtomValue, :expr, [:name, module: [:atoms]],
    type: quote(do: %__MODULE__{name: atom(), module: [atom() | String.t()]})
  )

  defnode(None, :expr, [], type: quote(do: %__MODULE__{}))

  defnode(Some, :expr, [:expr], type: quote(do: %__MODULE__{expr: AST.expr()}))

  defnode(Ok, :expr, [:expr], type: quote(do: %__MODULE__{expr: AST.expr() | nil}))

  defnode(Err, :expr, [:expr], type: quote(do: %__MODULE__{expr: AST.expr()}))

  defnode(NifRaiseAtom, :expr, [:name], type: quote(do: %__MODULE__{name: atom()}))

  defnode(BlockExpr, :expr, [body: []], type: quote(do: %__MODULE__{body: [AST.stmt()]}))

  defnode(UnsafeBlock, :expr, [body: []], type: quote(do: %__MODULE__{body: [AST.stmt()]}))

  defnode(Match, :expr, [:expr, arms: []],
    type: quote(do: %__MODULE__{expr: AST.expr(), arms: [Arm.t()]})
  )

  defnode(If, :expr, [:condition, then: [], else: []],
    type:
      quote(
        do: %__MODULE__{
          condition: AST.expr(),
          then: [AST.stmt()],
          else: [AST.stmt()]
        }
      )
  )

  defnode(BinaryOp, :expr, [:left, :op, :right],
    type:
      quote(
        do: %__MODULE__{
          left: AST.expr(),
          op: :eq | :ne | :lt | :lte | :gt | :gte | :add | :sub | :mul | :div | :rem | :and | :or,
          right: AST.expr()
        }
      )
  )

  defnode(Arm, :field, [:pattern, guard: nil, body: [], attrs: []],
    type:
      quote(
        do: %__MODULE__{
          pattern: AST.pat(),
          guard: AST.expr() | nil,
          body: [AST.stmt()],
          attrs: [AST.Attribute.t()]
        }
      )
  )

  defnode(PatVar, :pat, [:name, mutable: false],
    type: quote(do: %__MODULE__{name: atom(), mutable: boolean()})
  )

  defnode(PatWildcard, :pat, [], type: quote(do: %__MODULE__{}))

  defnode(PatPath, :pat, [:path], type: quote(do: %__MODULE__{path: Path.t()}))

  defnode(PatLiteral, :pat, [:value], type: quote(do: %__MODULE__{value: String.t() | atom()}))

  defnode(PatNone, :pat, [], type: quote(do: %__MODULE__{}))

  defnode(PatSome, :pat, [:pattern], type: quote(do: %__MODULE__{pattern: AST.pat()}))

  defnode(PatAtomGuard, :pat, [:name, module: [:atoms]],
    type: quote(do: %__MODULE__{name: atom(), module: [atom() | String.t()]})
  )

  defnode(PatTuple, :pat, [:patterns], type: quote(do: %__MODULE__{patterns: [AST.pat()]}))

  defnode(PatOk, :pat, [:pattern], type: quote(do: %__MODULE__{pattern: AST.pat()}))

  defnode(PatErr, :pat, [:pattern], type: quote(do: %__MODULE__{pattern: AST.pat()}))

  defnode(PatPathTuple, :pat, [:path, patterns: []],
    type: quote(do: %__MODULE__{path: Path.t(), patterns: [AST.pat()]})
  )

  defnode(PatStruct, :pat, [:path, fields: []],
    type: quote(do: %__MODULE__{path: Path.t(), fields: [{atom(), AST.pat()}]})
  )

  defnode(PatSlice, :pat, [patterns: [], rest: nil],
    type: quote(do: %__MODULE__{patterns: [AST.pat()], rest: AST.pat() | nil})
  )

  @doc "Returns whether a value is a structural Rust type node."
  @spec type_node?(term()) :: boolean()
  def type_node?(term), do: category_node?(term, :type)

  @doc "Returns whether a value is a structural Rust expression node."
  @spec expr_node?(term()) :: boolean()
  def expr_node?(term), do: category_node?(term, :expr)

  @doc "Returns whether a value is a structural Rust pattern node."
  @spec pat_node?(term()) :: boolean()
  def pat_node?(term), do: category_node?(term, :pat)

  defp category_node?(%{__struct__: module}, category) do
    Code.ensure_loaded?(module) and function_exported?(module, :__rustq_ast_category__, 0) and
      module.__rustq_ast_category__() == category
  end

  defp category_node?(_term, _category), do: false

  @doc false
  def __rustq_ast_modules__ do
    [
      Use,
      Attribute,
      Module,
      Const,
      Static,
      TypeAlias,
      MacroItem,
      MacroItemCall,
      MacroRules,
      MacroRule,
      MacroVar,
      MacroCapture,
      MacroRepeat,
      Impl,
      FunctionArg,
      Function,
      Derive,
      Struct,
      StructField,
      Enum,
      EnumVariant,
      TypePath,
      TypeRef,
      TypeOption,
      TypeResult,
      TypeNifResult,
      TypeVec,
      TypeSlice,
      TypeArray,
      TypeTuple,
      TypeBareFn,
      TypeImplTrait,
      TypeRaw,
      TypeUnit,
      Let,
      LetElse,
      Assign,
      AssignOp,
      ExprStmt,
      Return,
      EarlyReturn,
      IfLet,
      For,
      Loop,
      Break,
      Continue,
      Var,
      Path,
      Field,
      Index,
      Range,
      Cast,
      UnaryOp,
      PathCall,
      MethodCall,
      StructLiteral,
      LocalCall,
      Ref,
      Try,
      Tuple,
      VecLiteral,
      ArrayLiteral,
      MacroRepeatExpr,
      Closure,
      Literal,
      ByteString,
      EscapeExpr,
      TokenMacro,
      MacroCall,
      AtomValue,
      None,
      Some,
      Ok,
      Err,
      NifRaiseAtom,
      BlockExpr,
      UnsafeBlock,
      Match,
      If,
      BinaryOp,
      Arm,
      PatVar,
      PatWildcard,
      PatPath,
      PatLiteral,
      PatNone,
      PatSome,
      PatAtomGuard,
      PatTuple,
      PatOk,
      PatErr,
      PatPathTuple,
      PatStruct,
      PatSlice
    ]
  end
end
