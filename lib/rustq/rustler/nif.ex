defmodule RustQ.Rustler.Nif do
  @moduledoc """
  Generates Rustler NIF wrappers, stubs, `NifStruct` declarations, and raw `NIF_TERM` builders.

  Most helpers in this module use RustQ AST. The raw `NIF_TERM` builders are an
  explicit low-level Rustler escape boundary for unsafe wrapper APIs; prefer
  `RustQ.Rustler.Term` helpers when normal `Term<'a>` values are available.
  """

  use RustQ.Sigil

  alias RustQ.Rust
  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.ItemBuilder, as: I
  alias RustQ.Rust.Identifier
  alias RustQ.Syn.{Arg, Type}

  import RustQ.Rust.AST.ItemBuilder

  require A
  require I

  @type spec :: {atom() | String.t(), keyword()}

  @nif_term_builder_names [:map_from_nif_terms, :struct_from_nif_terms]

  @nif_term_builder_templates %{
    map_from_nif_terms: ~R"""
    fn make_map_from_nif_terms<'a>(
        env: Env<'a>,
        pairs: &[(rustler::wrapper::NIF_TERM, rustler::wrapper::NIF_TERM)],
    ) -> NifResult<Term<'a>> {
        let mut map = unsafe { rustler::wrapper::map::map_new(env.as_c_arg()) };

        for (key, value) in pairs {
            map = unsafe { rustler::wrapper::map::map_put(env.as_c_arg(), map, *key, *value) }
                .ok_or(rustler::Error::BadArg)?;
        }

        Ok(unsafe { Term::new(env, map) })
    }
    """,
    struct_from_nif_terms: ~R"""
    fn make_struct_from_nif_terms<'a>(
        env: Env<'a>,
        keys: &[rustler::wrapper::NIF_TERM],
        values: &[rustler::wrapper::NIF_TERM],
    ) -> NifResult<Term<'a>> {
        if keys.len() != values.len() {
            return Err(rustler::Error::BadArg);
        }

        let mut map = unsafe { rustler::wrapper::map::map_new(env.as_c_arg()) };

        for (key, value) in keys.iter().zip(values.iter()) {
            map = unsafe { rustler::wrapper::map::map_put(env.as_c_arg(), map, *key, *value) }
                .ok_or(rustler::Error::BadArg)?;
        }

        Ok(unsafe { Term::new(env, map) })
    }
    """
  }

  @doc "Builds the `rustler::init!` declaration for an Elixir module."
  @spec init(module() | String.t()) :: AST.MacroItemCall.t()
  def init(module) when is_atom(module), do: init(Elixir.Atom.to_string(module))

  def init(module) when is_binary(module) do
    %AST.MacroItemCall{
      path: A.path([:rustler, :init]),
      tokens: [%AST.Literal{value: module}]
    }
  end

  @doc "Builds a Rust struct deriving `NifStruct` for an Elixir struct module."
  @spec struct(atom() | String.t(), module() | String.t(), keyword()) :: AST.Struct.t()
  def struct(name, module, opts \\ []) do
    I.struct Identifier.atom!(to_string(name)),
      vis: Keyword.get(opts, :vis, :pub),
      derive: Keyword.get(opts, :derive, [:Clone, :Debug, :NifStruct]),
      attrs: [
        A.attr_value(:module, module_name(module))
        | normalize_attrs(Keyword.get(opts, :attrs, []))
      ] do
      struct_fields(Keyword.get(opts, :fields, []), Keyword.get(opts, :field_vis, :pub))
    end
  end

  @doc "Builds NIF wrappers from explicit export specifications."
  @spec wrappers([spec()]) :: [AST.Function.t()]
  def wrappers(specs) do
    Enum.map(specs, fn {name, opts} -> wrapper(name, opts) end)
  end

  @doc "Builds NIF wrappers whose signatures are derived from Rust functions in one source file."
  @spec wrappers_from_source(Path.t(), [spec()], keyword()) :: [AST.Function.t()]
  def wrappers_from_source(path, specs, defaults \\ []) do
    path
    |> source_exports(specs, defaults)
    |> Enum.map(fn {name, function, opts} ->
      derived = [
        args: Enum.map(function.args, &source_arg/1),
        returns: function.returns || :unit,
        lifetimes: Enum.map(function.lifetimes, &Identifier.atom!/1)
      ]

      wrapper(name, Keyword.merge(derived, opts))
    end)
  end

  @doc "Builds NIF wrappers from multiple `{source_path, specs}` groups."
  @spec wrappers_from_sources([{Path.t(), [spec()]}], keyword()) :: [AST.Function.t()]
  def wrappers_from_sources(groups, defaults \\ []) do
    Enum.flat_map(groups, fn {path, specs} -> wrappers_from_source(path, specs, defaults) end)
  end

  @doc "Returns selected, export-named Rust function metadata from one source file."
  @spec functions_from_source(Path.t(), [spec()], keyword()) :: [
          {atom() | String.t(), RustQ.Syn.Function.t()}
        ]
  def functions_from_source(path, specs, defaults \\ []) do
    path
    |> source_exports(specs, defaults)
    |> Enum.map(fn {name, function, _opts} -> {name, function} end)
  end

  @doc "Returns selected, export-named Rust function metadata from multiple source groups."
  @spec functions_from_sources([{Path.t(), [spec()]}], keyword()) ::
          [{atom() | String.t(), RustQ.Syn.Function.t()}]
  def functions_from_sources(groups, defaults \\ []) do
    Enum.flat_map(groups, fn {path, specs} -> functions_from_source(path, specs, defaults) end)
  end

  @doc "Builds an Elixir NIF-not-loaded stub module from one Rust source file."
  @spec stubs_from_source(Path.t(), [spec()], module(), keyword()) :: String.t()
  def stubs_from_source(path, specs, module, defaults \\ []) do
    path
    |> functions_from_source(specs, defaults)
    |> stubs_from_functions(module)
  end

  @doc "Builds one Elixir NIF-not-loaded stub module from multiple Rust source groups."
  @spec stubs_from_sources([{Path.t(), [spec()]}], module(), keyword()) :: String.t()
  def stubs_from_sources(groups, module, defaults \\ []) do
    groups
    |> functions_from_sources(defaults)
    |> stubs_from_functions(module)
  end

  @doc "Builds an Elixir stub module from mixed `RustQ.Syn.Function` and RustQ AST metadata."
  @spec stubs_from_functions(
          [RustQ.Syn.Function.t() | AST.Function.t() | {term(), term()}],
          module()
        ) ::
          String.t()
  def stubs_from_functions(functions, module) do
    definitions = Enum.map(functions, &stub_definition/1)
    quoted_body = {:quote, [], [[do: {:__block__, [], definitions}]]}

    quote do
      defmodule unquote(module) do
        @moduledoc """
        NIF stubs generated by RustQ from Rust source. `use` this module in the module that
        loads the NIF library to define a stub raising `:nif_not_loaded` for each NIF.
        """
        defmacro __using__(_opts), do: unquote(quoted_body)
      end
    end
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @doc "Builds one NIF wrapper that delegates to an implementation function."
  @spec wrapper(atom() | String.t(), keyword()) :: AST.Function.t()
  def wrapper(name, opts) do
    args = Keyword.get(opts, :args, [])
    impl = Keyword.get(opts, :impl, "#{name}_impl")

    function Identifier.atom!(to_string(name)),
      args: args,
      returns: Keyword.fetch!(opts, :returns),
      lifetimes: Keyword.get(opts, :lifetimes, []),
      vis: Keyword.get(opts, :vis),
      attrs: normalize_attrs(Keyword.get(opts, :attrs, [])) ++ [nif_attribute(opts)] do
      A.return(impl_call(impl, Keyword.keys(args)))
    end
  end

  @doc "Builds unsafe raw `NIF_TERM` map and struct helpers."
  @spec raw_term_builders(keyword()) :: [Rust.Fragment.t()]
  def raw_term_builders(opts \\ []) do
    opts
    |> Keyword.get(:include, @nif_term_builder_names)
    |> include_names()
    |> Enum.map(
      &Rust.fragment(
        :item,
        RustQ.render!(nif_term_builder_template!(&1), "rustler_nif_term_builder.rs")
      )
    )
  end

  defp struct_fields(fields, default_vis) do
    Enum.map(fields, fn
      %AST.StructField{} = rust_field ->
        rust_field

      {field_name, type} ->
        field(field_name, type, vis: default_vis)
    end)
  end

  defp normalize_attrs(attrs), do: Enum.map(attrs, &normalize_attr/1)
  defp normalize_attr(%AST.Attribute{} = attr), do: attr

  defp normalize_attr(attr) when is_list(attr),
    do: attr |> IO.iodata_to_binary() |> normalize_attr()

  defp normalize_attr(attr) when is_binary(attr) do
    cond do
      String.contains?(attr, " = ") ->
        [path, value] = String.split(attr, " = ", parts: 2)
        A.attr_value(Identifier.atom!(path), String.trim(value, ~s|"|))

      String.ends_with?(attr, ")") and String.contains?(attr, "(") ->
        [path, args] = String.split(String.trim_trailing(attr, ")"), "(", parts: 2)

        args =
          args
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&Identifier.atom!/1)

        A.attr(Identifier.atom!(path), args)

      true ->
        A.attr(Identifier.atom!(attr))
    end
  end

  defp source_exports(path, specs, defaults) do
    functions = path |> RustQ.Syn.parse_file!() |> RustQ.Syn.functions()

    Enum.map(specs, fn {name, opts} ->
      opts = Keyword.merge(defaults, opts)
      impl = Keyword.get(opts, :impl, "#{name}_impl")
      function = Enum.find(functions, &(&1.name == to_string(impl)))

      if function do
        {name, function, Keyword.put(opts, :impl, impl)}
      else
        raise ArgumentError, "NIF implementation #{impl} not found in #{path}"
      end
    end)
  end

  defp source_arg(%Arg{name: name, type: type}) when is_binary(name),
    do: {Identifier.atom!(name), type}

  defp impl_call(impl, args) do
    parts = impl |> to_string() |> String.split("::") |> Enum.map(&Identifier.atom!/1)

    case parts do
      [name] -> A.call(name, args)
      parts -> A.path_call(parts, args)
    end
  end

  defp stub_definition({name, function}) do
    stub_definition(function, name)
  end

  defp stub_definition(%{name: name} = function), do: stub_definition(function, name)

  defp stub_definition(function, name) do
    args = function |> stub_args() |> Enum.map(&stub_arg/1)
    name = Identifier.atom!(to_string(name))
    head = {name, [], if(args == [], do: nil, else: args)}

    quote do
      def unquote(head), do: :erlang.nif_error(:nif_not_loaded)
    end
  end

  defp stub_args(%RustQ.Syn.Function{args: args}), do: Enum.reject(args, &env_arg?/1)

  defp stub_args(%AST.Function{args: args}) do
    Enum.reject(args, fn
      %AST.FunctionArg{receiver: true} -> true
      %AST.FunctionArg{type: type} -> ast_env_type?(type)
    end)
  end

  defp env_arg?(%Arg{type_ast: type}), do: Type.path?(type, "Env")

  defp ast_env_type?(%AST.TypePath{parts: parts}), do: to_string(List.last(parts)) == "Env"
  defp ast_env_type?(_type), do: false

  defp stub_arg(%{name: name}) do
    Identifier.atom!("_#{name}")
    |> then(&{&1, [], nil})
  end

  defp nif_attribute(opts) do
    case Keyword.get(opts, :schedule) do
      nil -> A.nif_attr()
      :dirty_cpu -> A.nif_attr(schedule: "DirtyCpu")
      :dirty_io -> A.nif_attr(schedule: "DirtyIo")
      value when is_binary(value) -> A.nif_attr(schedule: value)
    end
  end

  defp include_names(:all), do: @nif_term_builder_names
  defp include_names(names), do: List.wrap(names)

  defp nif_term_builder_template!(name), do: Map.fetch!(@nif_term_builder_templates, name)

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(module) when is_binary(module), do: module
end
