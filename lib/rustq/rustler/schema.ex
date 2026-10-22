defmodule RustQ.Rustler.Schema do
  @moduledoc """
  Schema DSL for generating Rustler structs and tagged enums.

  Use this when a group of Elixir structs should be mirrored in Rust. A schema
  module defines nodes, fields, type aliases, and tagged enums; `rust_items/1`
  returns Rust fragments ready for `rustq.exs`.

      defmodule MyApp.Codegen.ContentSchema do
        use RustQ.Rustler.Schema

        schema MyApp.Content do
          node Text do
            field :text, :String
            field :size, {:option, :String}
          end

          node Paragraph do
            field :body, {:vec, Content}
          end

          tagged_enum Content do
            variants :all
          end
        end
      end

  Field optionality is encoded in the Rust type (`{:option, :String}`), keeping
  the schema close to the generated Rust.
  """
  alias RustQ.Diagnostic
  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.Identifier
  alias RustQ.Rustler.{Nif, TaggedEnum}

  defstruct module_prefix: nil,
            rust_prefix: "Ex",
            tag_field: :__struct__,
            default_attrs: [],
            type_aliases: [],
            nodes: [],
            enums: []

  @type rust_type :: AST.type() | String.t() | atom() | tuple()
  @type field :: {atom(), rust_type(), keyword()}
  @type schema_node :: {atom(), [field()], keyword()}
  @type enum_decl :: {atom(), keyword()}
  @type type_alias :: {atom(), rust_type()}
  @type t :: %__MODULE__{
          module_prefix: module(),
          rust_prefix: String.t(),
          tag_field: atom(),
          default_attrs: [term()],
          type_aliases: [type_alias()],
          nodes: [schema_node()],
          enums: [enum_decl()]
        }

  @doc """
  Imports the schema DSL and registers the attributes it accumulates; the `Ex` Rust prefix
  is the default.
  """
  defmacro __using__(_opts) do
    quote do
      import RustQ.Rustler.Schema

      Module.register_attribute(__MODULE__, :rustq_schema_nodes, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_schema_enums, accumulate: true)
      Module.register_attribute(__MODULE__, :rustq_schema_type_aliases, accumulate: true)
      @rustq_schema_rust_prefix "Ex"
      @rustq_schema_tag_field :__struct__
      @rustq_schema_default_attrs []
      @before_compile RustQ.Rustler.Schema
    end
  end

  @doc """
  Defines the schema module's `schema/0`, returning the declared `RustQ.Rustler.Schema`, and
  `rust_items/0`, returning its Rust items.
  """
  defmacro __before_compile__(_env) do
    quote do
      alias RustQ.Rustler.Schema, as: RustlerSchema

      def schema do
        %RustlerSchema{
          module_prefix: @rustq_schema_module_prefix,
          rust_prefix: @rustq_schema_rust_prefix,
          tag_field: @rustq_schema_tag_field,
          default_attrs: @rustq_schema_default_attrs,
          type_aliases: Enum.reverse(@rustq_schema_type_aliases),
          nodes: Enum.reverse(@rustq_schema_nodes),
          enums: Enum.reverse(@rustq_schema_enums)
        }
      end

      def rust_items do
        RustlerSchema.rust_items(schema())
      end
    end
  end

  @doc "Declares a Rustler schema for an Elixir module namespace."
  defmacro schema(module_prefix, opts \\ [], do: block) do
    module_prefix = Macro.expand(module_prefix, __CALLER__)

    quote do
      alias RustQ.Rustler.Schema, as: RustlerSchema

      @rustq_schema_module_prefix unquote(module_prefix)
      RustlerSchema.__apply_schema_opts__(__MODULE__, unquote(Macro.escape(opts)))
      unquote(block)
    end
  end

  @doc "Overrides the Rust type-name prefix for the current schema."
  defmacro rust_prefix(prefix) do
    quote do
      @rustq_schema_rust_prefix unquote(prefix)
    end
  end

  @doc "Sets the atom-keyed field used to identify tagged values."
  defmacro tag_field(field) do
    quote do
      @rustq_schema_tag_field unquote(field)
    end
  end

  @doc "Sets default Rust attributes for generated schema items."
  defmacro default_attrs(attrs) do
    quote do
      @rustq_schema_default_attrs unquote(attrs)
    end
  end

  @doc "Declares a reusable schema-local Rust type alias."
  defmacro type(name, rust_type) do
    quote do
      @rustq_schema_type_aliases {unquote(name), unquote(rust_type)}
    end
  end

  @doc """
  Records the `:rust_prefix`, `:tag_field`, and `:default_attrs` options of a `schema/3`
  declaration on the schema module.
  """
  @spec __apply_schema_opts__(module(), keyword()) :: term()
  def __apply_schema_opts__(module, opts) do
    if prefix = Keyword.get(opts, :rust_prefix) do
      Module.put_attribute(module, :rustq_schema_rust_prefix, prefix)
    end

    if tag = Keyword.get(opts, :tag_field) do
      Module.put_attribute(module, :rustq_schema_tag_field, tag)
    end

    if attrs = Keyword.get(opts, :default_attrs) do
      Module.put_attribute(module, :rustq_schema_default_attrs, attrs)
    end
  end

  @doc "Declares an Elixir struct-backed Rust `NifStruct` node."
  defmacro node(name, opts \\ [], do: block) do
    name = ast_name(name)
    opts = normalize_node_opts(opts, __CALLER__)
    fields = extract_fields(block)

    quote do
      @rustq_schema_nodes {unquote(name), unquote(Macro.escape(fields)),
                           unquote(Macro.escape(opts))}
    end
  end

  @doc "Declares a tagged enum over selected schema nodes."
  defmacro tagged_enum(name, opts \\ [], do: block) do
    name = ast_name(name)
    opts = Keyword.merge(opts, extract_enum_opts(block))

    quote do
      @rustq_schema_enums {unquote(name), unquote(Macro.escape(opts))}
    end
  end

  @doc "Builds structural Rust field fragments from `{name, type}` pairs."
  @spec struct_fields([{atom() | String.t(), AST.type() | String.t()}], keyword()) ::
          [AST.StructField.t()]
  def struct_fields(fields, opts \\ []) do
    Enum.map(fields, fn {name, type} ->
      %AST.StructField{
        name: Identifier.atom!(to_string(name)),
        type: type,
        vis: opts[:vis]
      }
    end)
  end

  @doc "Builds shorthand field fragments for Rust template splices."
  @spec shorthand_fields([atom() | String.t()]) :: [Rust.Fragment.t()]
  def shorthand_fields(names) do
    Enum.map(names, &Rust.fragment(:field, [to_string(&1), ","]))
  end

  @doc "Builds all structural Rust items for a schema."
  @spec rust_items(%__MODULE__{}) :: [AST.item()]
  def rust_items(%__MODULE__{} = schema) do
    schema.nodes
    |> Enum.map(&nif_struct(schema, &1))
    |> Kernel.++(Enum.flat_map(schema.enums, &tagged_enum_items(schema, &1)))
  end

  defp nif_struct(schema, {name, fields, opts}) do
    Nif.struct(node_rust_name(schema, name), module_name(schema, name),
      fields: Enum.map(fields, fn {field, type, _opts} -> {field, rust_type(schema, type)} end),
      attrs: attrs(schema, opts),
      derive: Keyword.get(opts, :derive, [:Clone, :Debug, :NifStruct]),
      vis: Keyword.get(opts, :vis, :pub),
      field_vis: Keyword.get(opts, :field_vis, :pub)
    )
  end

  defp tagged_enum_items(schema, {name, opts}) do
    variants =
      opts
      |> Keyword.get(:variants, :all)
      |> enum_variants(schema)
      |> Enum.map(fn variant ->
        {variant,
         [
           type: node_rust_name(schema, variant),
           module: elixir_module_name(schema, variant)
         ]}
      end)

    TaggedEnum.items(Keyword.get(opts, :rust, rust_name(schema, name)),
      tag: tag_expr(schema.tag_field),
      unknown: Keyword.get(opts, :unknown, :unknown_variant),
      variants: variants,
      attrs: enum_attrs(schema, opts),
      derive: Keyword.get(opts, :derive, [:Clone, :Debug]),
      vis: Keyword.get(opts, :vis, :pub)
    )
  end

  defp attrs(schema, opts), do: Keyword.get(opts, :attrs, schema.default_attrs)

  defp enum_attrs(schema, opts) do
    case attrs(schema, opts) do
      [] -> []
      attrs -> Enum.map(attrs, &enum_attr!/1)
    end
  end

  defp enum_attr!(%RustQ.Rust.AST.Attribute{} = attr), do: attr

  defp enum_attr!(other) do
    Diagnostic.render(
      :invalid_tagged_enum_attr,
      other,
      "tagged_enum attrs must be RustQ.Rust.AST.Attribute structs",
      details: %{attr: other},
      suggestion: "Pass attrs built with RustQ.Rust.AST.Builder.attr/2 or allow_attr/1."
    )
  end

  defp enum_variants(:all, schema), do: Enum.map(schema.nodes, &elem(&1, 0))
  defp enum_variants(variants, _schema), do: List.wrap(variants)

  defp rust_name(schema, name), do: "#{schema.rust_prefix}#{name}"

  defp node_rust_name(schema, name) do
    case node_opts(schema, name) |> Keyword.get(:rust) do
      nil -> rust_name(schema, name)
      rust -> rust
    end
  end

  defp module_name(schema, name) do
    case node_opts(schema, name) |> Keyword.get(:module) do
      nil -> default_module_name(schema, name)
      module -> module |> to_string() |> String.replace_prefix("Elixir.", "")
    end
  end

  defp default_module_name(schema, name) do
    "#{schema.module_prefix}.#{name}"
    |> String.replace_prefix("Elixir.", "")
  end

  defp elixir_module_name(schema, name), do: "Elixir.#{module_name(schema, name)}"

  defp node_opts(schema, name) do
    schema.nodes
    |> Enum.find_value([], fn
      {^name, _fields, opts} -> opts
      _node -> false
    end)
  end

  defp tag_expr(:__struct__), do: A.call(:atom_struct)
  defp tag_expr(field), do: A.path_call([:atoms, field])

  defp rust_type(_schema, :string), do: :String
  defp rust_type(_schema, :boolean), do: :bool
  defp rust_type(schema, {:option, type}), do: {:option, rust_type(schema, type)}
  defp rust_type(schema, {:vec, type}), do: {:vec, rust_type(schema, type)}

  defp rust_type(schema, type) when is_atom(type) do
    cond do
      alias_type = Keyword.get(schema.type_aliases, type) -> alias_type
      type in schema_names(schema) -> node_rust_name(schema, type)
      true -> type
    end
  end

  defp rust_type(_schema, type), do: type

  defp schema_names(schema) do
    Enum.map(schema.nodes, &elem(&1, 0)) ++ Enum.map(schema.enums, &elem(&1, 0))
  end

  defp normalize_node_opts(opts, env) do
    Enum.map(opts, fn
      {:rust, value} -> {:rust, ast_name(value)}
      {:module, value} -> {:module, Macro.expand(value, env)}
      opt -> opt
    end)
  end

  defp extract_fields(block) do
    block
    |> block_expressions()
    |> Enum.map(fn
      {:field, _meta, [name, type]} -> {name, normalize_type(type), []}
      {:field, _meta, [name, type, opts]} -> {name, normalize_type(type), opts}
      other -> raise ArgumentError, "unsupported node expression: #{Macro.to_string(other)}"
    end)
  end

  defp extract_enum_opts(block) do
    block
    |> block_expressions()
    |> Enum.map(fn
      {:variants, _meta, [variants]} ->
        {:variants, extract_variants(variants)}

      {:rust, _meta, [name]} ->
        {:rust, ast_name(name)}

      {:unknown, _meta, [name]} ->
        {:unknown, name}

      other ->
        raise ArgumentError, "unsupported tagged_enum expression: #{Macro.to_string(other)}"
    end)
  end

  defp extract_variants(:all), do: :all

  defp extract_variants(variants) when is_list(variants) do
    Enum.map(variants, &ast_name/1)
  end

  defp normalize_type({:__aliases__, _meta, _parts} = alias), do: ast_name(alias)
  defp normalize_type({left, right}), do: {normalize_type(left), normalize_type(right)}

  defp normalize_type(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_type/1)
    |> List.to_tuple()
  end

  defp normalize_type(list) when is_list(list), do: Enum.map(list, &normalize_type/1)
  defp normalize_type(type), do: ast_name(type)

  defp ast_name({:__aliases__, _meta, parts}), do: List.last(parts)
  defp ast_name(name) when is_atom(name), do: name
  defp ast_name(other), do: other

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]
end
