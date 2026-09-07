defmodule RustQ.Syn do
  @moduledoc """
  Structural metadata for Rust source parsed with [`syn`](https://docs.rs/syn).

  `RustQ.Syn` is for introspecting existing Rust source. It returns Elixir
  metadata for Rust items such as enums, structs, free functions, `impl` blocks,
  methods, docs, arguments, return types, and common Rust type shapes.

  This is **Rust AST metadata**, not Rusty Elixir AST and not `RustQ.Rust.AST`.
  Use it when a generator needs to understand Rust that already exists in an
  upstream crate, for example to discover a crate's methods or enum variants
  without parsing Rust text with regex.

  ## Example

      file = RustQ.Syn.parse_file!("native/my_crate/src/lib.rs")

      file
      |> RustQ.Syn.methods()
      |> Enum.find(&(&1.name == "draw_rect"))

  Arguments and returns keep both the rendered Rust type string and a structured
  type node:

      %RustQ.Syn.Arg{
        name: "paint",
        type: "& Paint",
        type_ast: %RustQ.Syn.Type.Ref{
          inner: %RustQ.Syn.Type.Path{name: "Paint"}
        }
      }

  The structured type vocabulary is intentionally partial. Unknown or currently
  unsupported Rust type forms are represented as `%RustQ.Syn.Type.Raw{}` with
  the original rendered code preserved.
  """

  alias RustQ.Error
  alias RustQ.Native.Nif

  defmodule File do
    @moduledoc """
    Rust source file metadata.

    The `items` list contains top-level item metadata structs such as
    `RustQ.Syn.Enum`, `RustQ.Syn.Struct`, `RustQ.Syn.Function`, and
    `RustQ.Syn.Impl`.
    """
    defstruct items: []

    @type t :: %__MODULE__{items: [RustQ.Syn.item()]}
  end

  defmodule Type do
    @moduledoc """
    Namespace for structured Rust type metadata.

    Each type node includes `code`, the rendered Rust tokens for display or
    diagnostics. Prefer matching on the structured fields when making semantic
    decisions.
    """

    alias RustQ.Syn.Type.Path
    alias RustQ.Syn.Type.Ref

    @doc "Returns true when `type` is a path whose final segment is `name`."
    @spec path?(RustQ.Syn.type(), String.t()) :: boolean()
    def path?(%{__struct__: Path, name: name}, name), do: true
    def path?(%{__struct__: Path, segments: segments}, name), do: List.last(segments) == name
    def path?(_type, _name), do: false

    @doc "Returns true when `type` is a reference to a path whose final segment is `name`."
    @spec ref_to?(RustQ.Syn.type(), String.t()) :: boolean()
    def ref_to?(%{__struct__: Ref, inner: inner}, name), do: path?(inner, name)
    def ref_to?(_type, _name), do: false

    @doc "Returns true when `type` is `impl Trait<Args...>` matching the requested trait and args."
    @spec impl_trait?(RustQ.Syn.type(), String.t(), [String.t()]) :: boolean()
    def impl_trait?(type, trait, args \\ [])

    def impl_trait?(%{__struct__: RustQ.Syn.Type.ImplTrait, traits: traits}, trait, args) do
      Enum.any?(traits, fn
        %{__struct__: RustQ.Syn.Type.Path, name: ^trait, args: trait_args} ->
          Enum.map(trait_args, &type_name/1) == args

        _other ->
          false
      end)
    end

    def impl_trait?(_type, _trait, _args), do: false

    @doc "Returns the final path-like name for common type metadata nodes."
    @spec type_name(RustQ.Syn.type()) :: String.t() | nil
    def type_name(%{__struct__: RustQ.Syn.Type.Path, name: name}), do: name
    def type_name(%{__struct__: RustQ.Syn.Type.Self}), do: "Self"
    def type_name(%{__struct__: RustQ.Syn.Type.Ref, inner: inner}), do: type_name(inner)
    def type_name(%{__struct__: RustQ.Syn.Type.Option, inner: inner}), do: type_name(inner)
    def type_name(_type), do: nil

    defmodule GenericArgument do
      @moduledoc "One ordered Rust path generic argument."
      defstruct [:kind, :name, :type, :source]

      @type kind :: :lifetime | :type | :const | :assoc_type | :assoc_const | :constraint
      @type t :: %__MODULE__{
              kind: kind(),
              name: String.t() | nil,
              type: RustQ.Syn.type() | nil,
              source: String.t() | nil
            }
    end

    defmodule Bound do
      @moduledoc "One ordered `impl Trait` bound."
      defstruct [:kind, :code, :path, :lifetime, :modifier, lifetimes: []]

      @type t :: %__MODULE__{
              kind: :trait | :lifetime | :precise_capture | :raw,
              code: String.t(),
              path: RustQ.Syn.Type.Path.t() | nil,
              lifetime: String.t() | nil,
              modifier: :maybe | nil,
              lifetimes: [String.t()]
            }
    end

    defmodule Path do
      @moduledoc "Rust path type metadata, for example `Paint`, `skia_safe::Canvas`, or `AsRef<Rect>`."
      defstruct [:code, :name, :callable, segments: [], args: [], assoc: %{}, generic_args: []]

      @type t :: %__MODULE__{
              code: String.t(),
              name: String.t(),
              segments: [String.t()],
              args: [RustQ.Syn.type()],
              assoc: %{optional(String.t()) => RustQ.Syn.type()},
              callable: %{args: [RustQ.Syn.type()], returns: RustQ.Syn.type() | nil} | nil,
              generic_args: [RustQ.Syn.Type.GenericArgument.t()]
            }
    end

    defmodule Ref do
      @moduledoc "Rust reference type metadata, for example `&Paint` or `&'a mut Path`."
      defstruct [:code, :inner, :lifetime, mutable: false]

      @type t :: %__MODULE__{
              code: String.t(),
              mutable: boolean(),
              lifetime: String.t() | nil,
              inner: RustQ.Syn.type()
            }
    end

    defmodule Tuple do
      @moduledoc "Rust tuple type metadata."
      defstruct [:code, elems: []]

      @type t :: %__MODULE__{code: String.t(), elems: [RustQ.Syn.type()]}
    end

    defmodule Option do
      @moduledoc "Rust Option<T> type metadata."
      defstruct [:code, :inner]

      @type t :: %__MODULE__{code: String.t(), inner: RustQ.Syn.type()}
    end

    defmodule Result do
      @moduledoc "Rust Result<T, E> type metadata."
      defstruct [:code, :ok, :error]

      @type t :: %__MODULE__{code: String.t(), ok: RustQ.Syn.type(), error: RustQ.Syn.type()}
    end

    defmodule ImplTrait do
      @moduledoc "Rust impl Trait type metadata."
      defstruct [:code, traits: [], bounds: []]

      @type t :: %__MODULE__{
              code: String.t(),
              traits: [RustQ.Syn.type()],
              bounds: [RustQ.Syn.Type.Bound.t()]
            }
    end

    defmodule Slice do
      @moduledoc "Rust slice type metadata."
      defstruct [:code, :inner]

      @type t :: %__MODULE__{code: String.t(), inner: RustQ.Syn.type()}
    end

    defmodule Array do
      @moduledoc "Rust fixed-size array type metadata."
      defstruct [:code, :inner, :length]

      @type t :: %__MODULE__{
              code: String.t(),
              inner: RustQ.Syn.type(),
              length: String.t() | nil
            }
    end

    defmodule Self do
      @moduledoc "Rust Self type metadata."
      defstruct [:code]

      @type t :: %__MODULE__{code: String.t()}
    end

    defmodule Fn do
      @moduledoc "Rust bare function pointer type metadata."
      defstruct [
        :code,
        :abi,
        :variadic_name,
        args: [],
        arg_names: [],
        returns: nil,
        lifetimes: [],
        unsafe: false,
        external: false,
        variadic: false
      ]

      @type t :: %__MODULE__{
              code: String.t(),
              args: [RustQ.Syn.type()],
              arg_names: [String.t() | nil],
              returns: RustQ.Syn.type() | nil,
              lifetimes: [String.t()],
              unsafe: boolean(),
              external: boolean(),
              abi: String.t() | nil,
              variadic: boolean(),
              variadic_name: String.t() | nil
            }
    end

    defmodule Raw do
      @moduledoc "Fallback Rust type metadata for type forms RustQ does not model structurally yet."
      defstruct [:code]

      @type t :: %__MODULE__{code: String.t()}
    end
  end

  defmodule Enum do
    @moduledoc "Rust enum metadata, including doc comments and variant names."
    defstruct [:name, :visibility, :source_line, :source_path, docs: [], variants: []]

    @type t :: %__MODULE__{
            name: String.t(),
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            docs: [String.t()],
            variants: [String.t()]
          }
  end

  defmodule Use do
    @moduledoc "Rust `use` item metadata, including reexport aliases."
    defstruct [
      :path,
      :alias,
      :visibility,
      :source_line,
      :source_path,
      docs: [],
      segments: [],
      glob?: false,
      module_path: []
    ]

    @type t :: %__MODULE__{
            path: String.t(),
            segments: [String.t()],
            alias: String.t() | nil,
            glob?: boolean(),
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            docs: [String.t()]
          }
  end

  defmodule Static do
    @moduledoc "Rust static item metadata."
    defstruct [
      :name,
      :visibility,
      :source_line,
      :source_path,
      :type,
      :type_ast,
      mutable: false,
      docs: []
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            type: String.t(),
            type_ast: RustQ.Syn.type(),
            mutable: boolean(),
            docs: [String.t()]
          }
  end

  defmodule TypeAlias do
    @moduledoc "Rust `type` alias metadata."
    defstruct [
      :name,
      :visibility,
      :source_line,
      :source_path,
      :type,
      :type_ast,
      docs: [],
      type_parameters: [],
      module_path: []
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            type: String.t(),
            type_ast: RustQ.Syn.type(),
            docs: [String.t()]
          }
  end

  defmodule Struct do
    @moduledoc "Rust struct metadata."
    defstruct [:name, :visibility, :source_line, :source_path, docs: [], fields: []]

    @type t :: %__MODULE__{
            name: String.t(),
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            docs: [String.t()],
            fields: [RustQ.Syn.Field.t()]
          }
  end

  defmodule Field do
    @moduledoc "Rust struct field metadata."
    defstruct [:name, :type, :type_ast]

    @type t :: %__MODULE__{name: String.t() | nil, type: String.t(), type_ast: RustQ.Syn.type()}
  end

  defmodule Function do
    @moduledoc "Rust free function metadata, including doc comments, arguments, and return type."
    defstruct [
      :name,
      :module_path,
      :visibility,
      :source_line,
      :source_path,
      :signature,
      :signature_ast,
      type_parameters: [],
      lifetimes: [],
      docs: [],
      args: [],
      returns: nil,
      returns_ast: nil
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            module_path: [String.t()] | nil,
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            signature: String.t() | nil,
            signature_ast: RustQ.Syn.Signature.t() | nil,
            lifetimes: [String.t()],
            docs: [String.t()],
            args: [RustQ.Syn.Arg.t()],
            returns: String.t() | nil,
            returns_ast: RustQ.Syn.type() | nil
          }
  end

  defmodule Arg do
    @moduledoc "Rust function or method argument metadata. `type` is rendered Rust; `type_ast` is structured metadata."
    defstruct [:name, :type, :type_ast]

    @type t :: %__MODULE__{name: String.t() | nil, type: String.t(), type_ast: RustQ.Syn.type()}
  end

  defmodule MethodCall do
    @moduledoc "Receiver method call metadata found in Rust source."
    defstruct [:receiver, :method]

    @type t :: %__MODULE__{receiver: String.t(), method: String.t()}
  end

  defmodule Signature do
    @moduledoc "Structured Rust function or method signature metadata."
    defstruct [:name, args: [], returns: nil]

    @type t :: %__MODULE__{
            name: String.t(),
            args: [RustQ.Syn.Arg.t()],
            returns: RustQ.Syn.type() | nil
          }

    @doc "Renders a signature from structured type metadata."
    @spec render(t()) :: String.t()
    def render(%__MODULE__{name: name, args: args, returns: returns}) do
      rendered_args = Elixir.Enum.map_join(args, ", ", &render_arg/1)
      rendered_returns = if returns, do: " -> #{render_type(returns)}", else: ""
      "fn #{name}(#{rendered_args})#{rendered_returns}"
    end

    defp render_arg(%RustQ.Syn.Arg{
           name: "self",
           type_ast: %RustQ.Syn.Type.Ref{lifetime: lifetime, mutable: mutable}
         }),
         do: render_reference(lifetime, mutable, "self")

    defp render_arg(%RustQ.Syn.Arg{name: "self", type_ast: type}), do: render_type(type)
    defp render_arg(%RustQ.Syn.Arg{name: nil, type_ast: type}), do: render_type(type)

    defp render_arg(%RustQ.Syn.Arg{name: name, type_ast: type}),
      do: "#{name}: #{render_type(type)}"

    defp render_type(%RustQ.Syn.Type.Path{
           segments: segments,
           callable: %{args: args, returns: returns}
         }) do
      output = if returns, do: " -> #{render_type(returns)}", else: ""

      "#{Elixir.Enum.join(segments, "::")}(#{Elixir.Enum.map_join(args, ", ", &render_type/1)})#{output}"
    end

    defp render_type(%RustQ.Syn.Type.Path{segments: segments, generic_args: [_ | _] = args}) do
      "#{Elixir.Enum.join(segments, "::")}<#{Elixir.Enum.map_join(args, ", ", &render_generic_argument/1)}>"
    end

    defp render_type(%RustQ.Syn.Type.Path{segments: segments, args: []}),
      do: Elixir.Enum.join(segments, "::")

    defp render_type(%RustQ.Syn.Type.Path{segments: segments, args: args}) do
      "#{Elixir.Enum.join(segments, "::")}<#{Elixir.Enum.map_join(args, ", ", &render_type/1)}>"
    end

    defp render_type(%RustQ.Syn.Type.Ref{
           inner: inner,
           lifetime: lifetime,
           mutable: mutable
         }),
         do: render_reference(lifetime, mutable, render_type(inner))

    defp render_type(%RustQ.Syn.Type.Tuple{elems: elems}),
      do: "(#{Elixir.Enum.map_join(elems, ", ", &render_type/1)})"

    defp render_type(%RustQ.Syn.Type.Option{inner: inner}), do: "Option<#{render_type(inner)}>"

    defp render_type(%RustQ.Syn.Type.Result{ok: ok, error: error}),
      do: "Result<#{render_type(ok)}, #{render_type(error)}>"

    defp render_type(%RustQ.Syn.Type.ImplTrait{bounds: [_ | _] = bounds}),
      do: "impl #{Elixir.Enum.map_join(bounds, " + ", &render_bound/1)}"

    defp render_type(%RustQ.Syn.Type.ImplTrait{traits: traits}),
      do: "impl #{Elixir.Enum.map_join(traits, " + ", &render_type/1)}"

    defp render_type(%RustQ.Syn.Type.Slice{inner: inner}), do: "[#{render_type(inner)}]"

    defp render_type(%RustQ.Syn.Type.Array{inner: inner, length: length})
         when is_binary(length),
         do: "[#{render_type(inner)}; #{length}]"

    defp render_type(%RustQ.Syn.Type.Array{code: code}), do: code

    defp render_type(%RustQ.Syn.Type.Fn{} = type), do: render_bare_fn(type)

    defp render_type(%RustQ.Syn.Type.Self{}), do: "Self"
    defp render_type(%RustQ.Syn.Type.Raw{code: code}), do: code

    defp render_generic_argument(%RustQ.Syn.Type.GenericArgument{kind: :type, type: type}),
      do: render_type(type)

    defp render_generic_argument(%RustQ.Syn.Type.GenericArgument{kind: :assoc_type} = arg),
      do: "#{arg.name} = #{render_type(arg.type)}"

    defp render_generic_argument(%RustQ.Syn.Type.GenericArgument{
           kind: :lifetime,
           source: source
         }),
         do: source

    defp render_generic_argument(%RustQ.Syn.Type.GenericArgument{kind: :const, source: source}),
      do: source

    defp render_generic_argument(%RustQ.Syn.Type.GenericArgument{
           kind: :constraint,
           source: source
         }),
         do: source

    defp render_generic_argument(%RustQ.Syn.Type.GenericArgument{name: name, source: source}),
      do: if(name, do: "#{name} = #{source}", else: source)

    defp render_bound(%RustQ.Syn.Type.Bound{kind: :trait} = bound) do
      modifier = if bound.modifier == :maybe, do: "?", else: ""

      lifetimes =
        if bound.lifetimes == [], do: "", else: "for<#{Elixir.Enum.join(bound.lifetimes, ", ")}> "

      "#{modifier}#{lifetimes}#{render_type(bound.path)}"
    end

    defp render_bound(%RustQ.Syn.Type.Bound{code: code}), do: code

    defp render_bare_fn(type) do
      prefix = render_bare_fn_prefix(type)
      args = type |> render_bare_fn_args() |> Elixir.Enum.join(", ")
      returns = if type.returns, do: " -> #{render_type(type.returns)}", else: ""
      "#{prefix}fn(#{args})#{returns}"
    end

    defp render_bare_fn_prefix(type) do
      lifetimes =
        if type.lifetimes == [], do: "", else: "for<#{Elixir.Enum.join(type.lifetimes, ", ")}> "

      unsafe = if type.unsafe, do: "unsafe ", else: ""

      external =
        cond do
          type.external and type.abi -> "extern #{inspect(type.abi)} "
          type.external -> "extern "
          true -> ""
        end

      "#{lifetimes}#{unsafe}#{external}"
    end

    defp render_bare_fn_args(type) do
      arg_names = type.arg_names ++ List.duplicate(nil, length(type.args))

      args =
        type.args
        |> Elixir.Enum.zip(arg_names)
        |> Elixir.Enum.map(fn
          {arg, nil} -> render_type(arg)
          {arg, name} -> "#{name}: #{render_type(arg)}"
        end)

      variadic = if type.variadic_name, do: "#{type.variadic_name}: ...", else: "..."
      if type.variadic, do: args ++ [variadic], else: args
    end

    defp render_reference(lifetime, mutable, inner) do
      lifetime = if lifetime, do: "#{lifetime} ", else: ""
      mutable = if mutable, do: "mut ", else: ""
      "&#{lifetime}#{mutable}#{inner}"
    end
  end

  defmodule Impl do
    @moduledoc "Rust impl block metadata, including target type, optional trait, doc comments, and methods."
    defstruct [:target, :target_ast, :trait, :source_line, :source_path, docs: [], methods: []]

    @type t :: %__MODULE__{
            target: String.t(),
            target_ast: RustQ.Syn.type(),
            trait: String.t() | nil,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            docs: [String.t()],
            methods: [RustQ.Syn.Method.t()]
          }
  end

  defmodule Method do
    @moduledoc "Rust impl method metadata, including doc comments, arguments, and return type."
    defstruct [
      :name,
      :visibility,
      :source_line,
      :source_path,
      :signature,
      :signature_ast,
      type_parameters: [],
      docs: [],
      args: [],
      returns: nil,
      returns_ast: nil
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            visibility: :public | :private,
            source_line: pos_integer() | nil,
            source_path: Path.t() | nil,
            signature: String.t() | nil,
            signature_ast: RustQ.Syn.Signature.t() | nil,
            docs: [String.t()],
            args: [RustQ.Syn.Arg.t()],
            returns: String.t() | nil,
            returns_ast: RustQ.Syn.type() | nil
          }
  end

  @type type ::
          RustQ.Syn.Type.Path.t()
          | RustQ.Syn.Type.Ref.t()
          | RustQ.Syn.Type.Tuple.t()
          | RustQ.Syn.Type.Option.t()
          | RustQ.Syn.Type.Result.t()
          | RustQ.Syn.Type.ImplTrait.t()
          | RustQ.Syn.Type.Slice.t()
          | RustQ.Syn.Type.Array.t()
          | RustQ.Syn.Type.Self.t()
          | RustQ.Syn.Type.Fn.t()
          | RustQ.Syn.Type.Raw.t()

  @type item ::
          RustQ.Syn.Enum.t()
          | RustQ.Syn.Use.t()
          | RustQ.Syn.Static.t()
          | RustQ.Syn.TypeAlias.t()
          | RustQ.Syn.Struct.t()
          | RustQ.Syn.Function.t()
          | RustQ.Syn.Impl.t()

  @doc """
  Parses Rust source into structural metadata.

  Returns `{:ok, %RustQ.Syn.File{}}` on success. Parser errors are returned in
  RustQ's normal template-error shape.
  """
  @spec parse(String.t()) :: {:ok, RustQ.Syn.File.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    with {:ok, raw_items} <- Nif.syn_inspect(source) do
      {:ok, %RustQ.Syn.File{items: Elixir.Enum.map(raw_items, &decode_item!/1)}}
    end
  end

  @doc """
  Parses Rust source into structural metadata, raising `RustQ.Error` on failure.
  """
  @spec parse!(String.t()) :: RustQ.Syn.File.t()
  def parse!(source) when is_binary(source) do
    case parse(source) do
      {:ok, file} ->
        file

      {:error, errors} ->
        raise Error, message: "RustQ syn parse error: #{inspect(errors)}", errors: errors
    end
  end

  @doc """
  Reads and parses a Rust source file.

  File read errors are returned as `{:error, reason}`. Rust parse errors are
  returned as `{:error, errors}`.
  """
  @spec parse_file(Path.t()) :: {:ok, RustQ.Syn.File.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, source} <- Elixir.File.read(path) do
      parse(source)
    end
  end

  @doc """
  Reads and parses a Rust source file, raising on file or Rust parse errors.
  """
  @spec parse_file!(Path.t()) :: RustQ.Syn.File.t()
  def parse_file!(path) do
    path
    |> Elixir.File.read!()
    |> parse!()
  end

  @doc "Returns top-level Rust enum metadata from a parsed file."
  @spec enums(RustQ.Syn.File.t()) :: [RustQ.Syn.Enum.t()]
  def enums(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.Enum{}, &1))

  @doc "Returns top-level Rust `use` alias metadata from a parsed file."
  @spec uses(RustQ.Syn.File.t()) :: [RustQ.Syn.Use.t()]
  def uses(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.Use{}, &1))

  @doc "Returns top-level Rust static item metadata from a parsed file."
  @spec statics(RustQ.Syn.File.t()) :: [RustQ.Syn.Static.t()]
  def statics(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.Static{}, &1))

  @doc "Returns top-level Rust type alias metadata from a parsed file."
  @spec type_aliases(RustQ.Syn.File.t()) :: [RustQ.Syn.TypeAlias.t()]
  def type_aliases(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.TypeAlias{}, &1))

  @doc "Returns top-level Rust struct metadata from a parsed file."
  @spec structs(RustQ.Syn.File.t()) :: [RustQ.Syn.Struct.t()]
  def structs(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.Struct{}, &1))

  @doc "Returns top-level Rust free function metadata from a parsed file."
  @spec functions(RustQ.Syn.File.t()) :: [RustQ.Syn.Function.t()]
  def functions(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.Function{}, &1))

  @doc "Returns top-level Rust impl block metadata from a parsed file."
  @spec impls(RustQ.Syn.File.t()) :: [RustQ.Syn.Impl.t()]
  def impls(%RustQ.Syn.File{items: items}),
    do: Elixir.Enum.filter(items, &match?(%RustQ.Syn.Impl{}, &1))

  @doc """
  Returns methods from all top-level Rust impl blocks in a parsed file.

  Use `impls/1` when the containing impl target or trait matters.
  """
  @spec methods(RustQ.Syn.File.t()) :: [RustQ.Syn.Method.t()]
  def methods(%RustQ.Syn.File{} = file),
    do: file |> impls() |> Elixir.Enum.flat_map(& &1.methods)

  @doc """
  Returns variants for a named top-level enum from Rust source.

  This is a focused helper for code generators that only need enum variants and
  do not need the full `RustQ.Syn.File` metadata.
  """
  @spec enum_variants(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def enum_variants(source, enum_name) when is_binary(source) and is_binary(enum_name),
    do: Nif.syn_enum_variants(source, enum_name)

  @doc """
  Returns atom names referenced as `atoms::name()` calls in Rust source.

  Pass `module: "a"` to discover calls through another atom module. This is
  intended for generators that need to keep `rustler::atoms!` in sync with
  existing Rust code without scraping source text. The source is parsed by
  `syn`; invalid Rust returns a normal RustQ parse error.
  """
  @spec atom_references(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def atom_references(source, opts \\ []) when is_binary(source) and is_list(opts) do
    module = Keyword.get(opts, :module, "atoms")

    unless is_binary(module) do
      raise ArgumentError, "expected :module to be a Rust module name string"
    end

    Nif.syn_atom_references(source, module)
  end

  @doc "Returns referenced atom names in Rust source, raising on failure."
  @spec atom_references!(String.t(), keyword()) :: [String.t()]
  def atom_references!(source, opts \\ []) do
    case atom_references(source, opts) do
      {:ok, atoms} ->
        atoms

      {:error, errors} ->
        raise Error,
          message: "RustQ atom reference introspection error: #{inspect(errors)}",
          errors: errors
    end
  end

  @doc """
  Returns receiver method calls found in Rust source.

  For example, `canvas.draw_rect(...)` contributes
  `%RustQ.Syn.MethodCall{receiver: "canvas", method: "draw_rect"}`.
  """
  @spec method_calls(String.t()) :: {:ok, [RustQ.Syn.MethodCall.t()]} | {:error, term()}
  def method_calls(source) when is_binary(source) do
    case Nif.syn_method_calls(source) do
      {:ok, calls} -> {:ok, Elixir.Enum.map(calls, &decode_method_call!/1)}
      {:error, errors} -> {:error, errors}
    end
  end

  @doc "Returns receiver method calls found in Rust source, raising on failure."
  @spec method_calls!(String.t()) :: [RustQ.Syn.MethodCall.t()]
  def method_calls!(source) do
    case method_calls(source) do
      {:ok, calls} ->
        calls

      {:error, errors} ->
        raise Error,
          message: "RustQ method call introspection error: #{inspect(errors)}",
          errors: errors
    end
  end

  @doc """
  Returns method names referenced as receiver method calls in Rust source.

  For example, `canvas.draw_rect(...)` contributes `"draw_rect"`.
  """
  @spec method_references(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def method_references(source) when is_binary(source),
    do: Nif.syn_method_references(source)

  @doc "Returns method names referenced as receiver method calls in Rust source, raising on failure."
  @spec method_references!(String.t()) :: [String.t()]
  def method_references!(source) do
    case method_references(source) do
      {:ok, methods} ->
        methods

      {:error, errors} ->
        raise Error,
          message: "RustQ method reference introspection error: #{inspect(errors)}",
          errors: errors
    end
  end

  @doc "Returns variants for a named top-level enum from Rust source, raising on failure."
  @spec enum_variants!(String.t(), String.t()) :: [String.t()]
  def enum_variants!(source, enum_name) do
    case enum_variants(source, enum_name) do
      {:ok, variants} ->
        variants

      {:error, errors} ->
        raise Error, message: "RustQ enum introspection error: #{inspect(errors)}", errors: errors
    end
  end

  defp decode_method_call!({receiver, method}) do
    %RustQ.Syn.MethodCall{receiver: receiver, method: method}
  end

  defp decode_item!({"enum", name, visibility, source_line, docs, variants}) do
    %RustQ.Syn.Enum{
      name: name,
      visibility: decode_visibility!(visibility),
      source_line: source_line,
      docs: docs,
      variants: variants
    }
  end

  defp decode_item!({"use", path, segments, alias, glob?, {modules, visibility, line}, docs}) do
    use = decode_item!({"use", path, segments, alias, glob?, {visibility, line}, docs})
    %{use | module_path: modules}
  end

  defp decode_item!({"use", path, segments, alias, glob?, {visibility, source_line}, docs}) do
    %RustQ.Syn.Use{
      path: path,
      segments: segments,
      alias: alias,
      glob?: glob?,
      visibility: decode_visibility!(visibility),
      source_line: source_line,
      docs: docs
    }
  end

  defp decode_item!({"static", name, visibility, source_line, docs, {type, type_ast, mutable}}) do
    %RustQ.Syn.Static{
      name: name,
      visibility: decode_visibility!(visibility),
      source_line: source_line,
      docs: docs,
      type: type,
      type_ast: decode_type!(type_ast),
      mutable: mutable
    }
  end

  defp decode_item!({"type_alias", name, visibility, {modules, line}, docs, type, type_ast}) do
    alias_type = decode_item!({"type_alias", name, visibility, line, docs, type, type_ast})
    %{alias_type | module_path: modules}
  end

  defp decode_item!(
         {"type_alias", name, visibility, source_line, docs, {type, parameters}, type_ast}
       ) do
    alias_type = decode_item!({"type_alias", name, visibility, source_line, docs, type, type_ast})
    %{alias_type | type_parameters: parameters}
  end

  defp decode_item!({"type_alias", name, visibility, source_line, docs, type, type_ast}) do
    %RustQ.Syn.TypeAlias{
      name: name,
      visibility: decode_visibility!(visibility),
      source_line: source_line,
      docs: docs,
      type: type,
      type_ast: decode_type!(type_ast)
    }
  end

  defp decode_item!({"struct", name, visibility, source_line, docs, fields}) do
    %RustQ.Syn.Struct{
      name: name,
      visibility: decode_visibility!(visibility),
      source_line: source_line,
      docs: docs,
      fields: Elixir.Enum.map(fields, &decode_field!/1)
    }
  end

  defp decode_item!(
         {"function", name, {module_path, visibility}, {source_line, signature, lifetimes}, docs,
          args, returns}
       ) do
    function =
      decode_callable!(
        RustQ.Syn.Function,
        name,
        module_path,
        visibility,
        {source_line, signature},
        docs,
        args,
        returns
      )

    %{function | lifetimes: lifetimes}
  end

  defp decode_item!(
         {"function", name, {module_path, visibility}, {source_line, signature}, docs, args,
          returns}
       ) do
    decode_callable!(
      RustQ.Syn.Function,
      name,
      module_path,
      visibility,
      {source_line, signature},
      docs,
      args,
      returns
    )
  end

  defp decode_item!({"function", name, visibility, {source_line, signature}, docs, args, returns}) do
    decode_callable!(
      RustQ.Syn.Function,
      name,
      [],
      visibility,
      {source_line, signature},
      docs,
      args,
      returns
    )
  end

  defp decode_item!(
         {"function", name, module_path, visibility, {source_line, signature}, docs, args,
          returns}
       ) do
    decode_callable!(
      RustQ.Syn.Function,
      name,
      module_path,
      visibility,
      {source_line, signature},
      docs,
      args,
      returns
    )
  end

  defp decode_item!({"impl", target, target_ast, trait, {line, _parameters}, docs, methods}),
    do: decode_item!({"impl", target, target_ast, trait, line, docs, methods})

  defp decode_item!({"impl", target, target_ast, trait, source_line, docs, methods}) do
    %RustQ.Syn.Impl{
      target: target,
      target_ast: decode_type!(target_ast),
      trait: trait,
      source_line: source_line,
      docs: docs,
      methods: Elixir.Enum.map(methods, &decode_method!/1)
    }
  end

  defp decode_field!({name, type, type_ast}) do
    %RustQ.Syn.Field{name: name, type: type, type_ast: decode_type!(type_ast)}
  end

  defp decode_method!(
         {"method", name, visibility, {line, signature, parameters}, docs, args, returns}
       ) do
    method = decode_method!({"method", name, visibility, {line, signature}, docs, args, returns})
    %{method | type_parameters: parameters}
  end

  defp decode_method!({"method", name, visibility, {source_line, signature}, docs, args, returns}) do
    decode_callable!(
      RustQ.Syn.Method,
      name,
      nil,
      visibility,
      {source_line, signature},
      docs,
      args,
      returns
    )
  end

  defp decode_callable!(
         module,
         name,
         module_path,
         visibility,
         {source_line, signature},
         docs,
         args,
         returns
       ) do
    {returns, returns_ast} = decode_return(returns)
    args = decode_args(args)

    struct(module, %{
      name: name,
      module_path: module_path,
      visibility: decode_visibility!(visibility),
      source_line: source_line,
      signature: signature,
      signature_ast: %RustQ.Syn.Signature{name: name, args: args, returns: returns_ast},
      docs: docs,
      args: args,
      returns: returns,
      returns_ast: returns_ast
    })
  end

  defp decode_args(args), do: Elixir.Enum.map(args, &decode_arg!/1)

  defp decode_arg!({name, type, type_ast}) do
    %RustQ.Syn.Arg{name: name, type: type, type_ast: decode_type!(type_ast)}
  end

  defp decode_return(nil), do: {nil, nil}
  defp decode_return({type, type_ast}), do: {type, decode_type!(type_ast)}

  defp decode_type!({"path", code, segments, args}) do
    decode_path_type!(code, segments, args, [], [])
  end

  defp decode_type!({"path", code, segments, args, assoc}) do
    decode_path_type!(code, segments, args, assoc, [])
  end

  defp decode_type!({"callable_path", code, segments, args, returns}) do
    %RustQ.Syn.Type.Path{
      code: code,
      name: List.last(segments),
      segments: segments,
      callable: %{
        args: Elixir.Enum.map(args, &decode_type!/1),
        returns: if(returns, do: decode_type!(returns))
      }
    }
  end

  defp decode_type!({"path", code, segments, args, assoc, generic_args}) do
    decode_path_type!(code, segments, args, assoc, generic_args)
  end

  defp decode_type!({"ref", code, mutable, lifetime, inner}) do
    %RustQ.Syn.Type.Ref{
      code: code,
      mutable: mutable,
      lifetime: lifetime,
      inner: decode_type!(inner)
    }
  end

  defp decode_type!({"tuple", code, elems}) do
    %RustQ.Syn.Type.Tuple{code: code, elems: Elixir.Enum.map(elems, &decode_type!/1)}
  end

  defp decode_type!({"option", code, inner}) do
    %RustQ.Syn.Type.Option{code: code, inner: decode_type!(inner)}
  end

  defp decode_type!({"result", code, ok, error}) do
    %RustQ.Syn.Type.Result{code: code, ok: decode_type!(ok), error: decode_type!(error)}
  end

  defp decode_type!({"impl_trait", code, traits, bounds}) do
    %RustQ.Syn.Type.ImplTrait{
      code: code,
      traits: Elixir.Enum.map(traits, &decode_type!/1),
      bounds: Elixir.Enum.map(bounds, &decode_bound!/1)
    }
  end

  defp decode_type!({"slice", code, inner}) do
    %RustQ.Syn.Type.Slice{code: code, inner: decode_type!(inner)}
  end

  defp decode_type!({"array", code, inner, length}) do
    %RustQ.Syn.Type.Array{code: code, inner: decode_type!(inner), length: length}
  end

  defp decode_type!({"self", code}), do: %RustQ.Syn.Type.Self{code: code}

  defp decode_type!({
         "fn",
         code,
         {lifetimes, unsafe, external, abi},
         {args, arg_names, variadic, variadic_name},
         returns
       }) do
    %RustQ.Syn.Type.Fn{
      code: code,
      lifetimes: lifetimes,
      unsafe: unsafe,
      external: external,
      abi: abi,
      args: Elixir.Enum.map(args, &decode_type!/1),
      arg_names: arg_names,
      variadic: variadic,
      variadic_name: variadic_name,
      returns: if(is_nil(returns), do: nil, else: decode_type!(returns))
    }
  end

  defp decode_type!({"raw", code}), do: %RustQ.Syn.Type.Raw{code: code}

  defp decode_path_type!(code, segments, args, assoc, generic_args) do
    %RustQ.Syn.Type.Path{
      code: code,
      name: List.last(segments),
      segments: segments,
      args: Elixir.Enum.map(args, &decode_type!/1),
      assoc: Map.new(assoc, fn {name, type} -> {name, decode_type!(type)} end),
      generic_args: Elixir.Enum.map(generic_args, &decode_generic_argument!/1)
    }
  end

  defp decode_generic_argument!({"lifetime", source}),
    do: %RustQ.Syn.Type.GenericArgument{kind: :lifetime, source: source}

  defp decode_generic_argument!({"type", type}),
    do: %RustQ.Syn.Type.GenericArgument{kind: :type, type: decode_type!(type)}

  defp decode_generic_argument!({"const", source}),
    do: %RustQ.Syn.Type.GenericArgument{kind: :const, source: source}

  defp decode_generic_argument!({"assoc_type", name, type}),
    do: %RustQ.Syn.Type.GenericArgument{kind: :assoc_type, name: name, type: decode_type!(type)}

  defp decode_generic_argument!({"assoc_const", name, source}),
    do: %RustQ.Syn.Type.GenericArgument{kind: :assoc_const, name: name, source: source}

  defp decode_generic_argument!({"constraint", name, source}),
    do: %RustQ.Syn.Type.GenericArgument{kind: :constraint, name: name, source: source}

  defp decode_bound!({"trait", code, modifier, lifetimes, path}) do
    %RustQ.Syn.Type.Bound{
      kind: :trait,
      code: code,
      modifier: if(modifier == "maybe", do: :maybe),
      lifetimes: lifetimes,
      path: decode_type!(path)
    }
  end

  defp decode_bound!({"lifetime", lifetime}),
    do: %RustQ.Syn.Type.Bound{kind: :lifetime, code: lifetime, lifetime: lifetime}

  defp decode_bound!({"precise_capture", code}),
    do: %RustQ.Syn.Type.Bound{kind: :precise_capture, code: code}

  defp decode_bound!({"raw", code}),
    do: %RustQ.Syn.Type.Bound{kind: :raw, code: code}

  defp decode_visibility!("public"), do: :public
  defp decode_visibility!("private"), do: :private
end
