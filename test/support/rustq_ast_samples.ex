defmodule RustQ.ASTSamples do
  @moduledoc """
  Behavioral sample AST nodes used by schema and native rendering tests.
  """

  alias RustQ.Rust.AST
  alias RustQ.Rust.AST.Builder, as: A
  alias RustQ.Rust.AST.MacroItem
  alias RustQ.Rust.AST.MacroItemCall
  alias RustQ.Rust.AST.Module
  alias RustQ.Rust.AST.PatternBuilder, as: P
  alias RustQ.Rust.AST.Render
  alias RustQ.Rust.AST.Schema
  alias RustQ.Rust.AST.Use

  require A

  def all do
    Schema.nodes()
    |> Map.new(fn node -> {node.name, sample_for(node.name)} end)
  end

  def validate_rendered?(name, ast, source) when is_binary(source) do
    source =~ base_fragment(ast) and source =~ semantic_fragment(name)
  end

  defp base_fragment(%Use{parts: parts}) when is_list(parts),
    do: "use #{Enum.map_join(parts, "::", &to_string/1)};"

  defp base_fragment(%Use{group: {base, names}}) do
    "use #{Enum.map_join(base, "::", &to_string/1)}::{#{Enum.map_join(names, ", ", &to_string/1)}};"
  end

  defp base_fragment(%Use{tree: tree}), do: "use #{tree};"
  defp base_fragment(%Module{name: name}), do: "mod #{name}"
  defp base_fragment(%MacroItem{source: source}), do: source

  defp base_fragment(%MacroItemCall{path: path}) do
    [Render.render_expr(path), "!"] |> IO.iodata_to_binary()
  end

  defp base_fragment(%AST.MacroRules{name: name}), do: "macro_rules! #{name}"

  defp base_fragment(%AST.Const{name: name}), do: "const #{name}"
  defp base_fragment(%AST.Static{name: name}), do: "static #{name}"
  defp base_fragment(%AST.TypeAlias{name: name}), do: "type #{name}"

  defp base_fragment(%AST.Impl{target: target}),
    do: "impl #{Render.render_type(target)}"

  defp base_fragment(%AST.Struct{name: name}), do: "struct #{name}"
  defp base_fragment(%AST.Enum{name: name}), do: "enum #{name}"
  defp base_fragment(%AST.Function{name: name}), do: "fn #{name}"

  defp semantic_fragment(:module), do: "mod sample"
  defp semantic_fragment(:macro_item_call), do: "rustler::atoms!"
  defp semantic_fragment(:macro_rules), do: "fn $name:ident;"
  defp semantic_fragment(:macro_rule), do: "fn $name:ident;"
  defp semantic_fragment(:macro_var), do: "$name:ident"
  defp semantic_fragment(:macro_capture), do: "fn $name ()"
  defp semantic_fragment(:macro_repeat), do: "$($field:ident;)*"
  defp semantic_fragment(:attribute), do: ~s|#[allow(dead_code)]|
  defp semantic_fragment(:type_alias), do: "type Bytes = Vec<u8>;"
  defp semantic_fragment(:impl), do: "impl Sample"
  defp semantic_fragment(:function_arg), do: "value: u32"
  defp semantic_fragment(:derive), do: "#[derive(Clone, serde::Serialize)]"
  defp semantic_fragment(:struct_field), do: "value: u32"
  defp semantic_fragment(:enum_variant), do: "Unit"
  defp semantic_fragment(:type_path), do: "type_path_VALUE: u32"
  defp semantic_fragment(:type_ref), do: "type_ref_VALUE: &str"
  defp semantic_fragment(:type_option), do: "Option<u32>"
  defp semantic_fragment(:type_result), do: "Result<u32, String>"
  defp semantic_fragment(:type_nif_result), do: "NifResult<u32>"
  defp semantic_fragment(:type_vec), do: "Vec<u8>"
  defp semantic_fragment(:type_slice), do: "type_slice_VALUE: [&str]"
  defp semantic_fragment(:type_array), do: "type_array_VALUE: [u8; 4]"
  defp semantic_fragment(:type_raw), do: "type_raw_VALUE: std::marker::PhantomData"
  defp semantic_fragment(:type_unit), do: "type_unit_VALUE: ()"
  defp semantic_fragment(:let), do: "let value = 1;"
  defp semantic_fragment(:let_else), do: "let Some(value) = maybe"
  defp semantic_fragment(:assign), do: "value = 2;"
  defp semantic_fragment(:expr_stmt), do: "side_effect();"
  defp semantic_fragment(:return), do: "1"
  defp semantic_fragment(:early_return), do: "return 1;"
  defp semantic_fragment(:if_let), do: "if let Some(value) = maybe"
  defp semantic_fragment(:for), do: "for value in values"
  defp semantic_fragment(:loop), do: "loop"
  defp semantic_fragment(:break), do: "break;"
  defp semantic_fragment(:continue), do: "continue;"
  defp semantic_fragment(:var), do: "value"
  defp semantic_fragment(:path), do: "Sample::VALUE"
  defp semantic_fragment(:field), do: "opts.value"
  defp semantic_fragment(:index), do: "values[0]"
  defp semantic_fragment(:range), do: "start..stop"
  defp semantic_fragment(:cast), do: "value as f32"
  defp semantic_fragment(:unary_op), do: "!condition"
  defp semantic_fragment(:path_call), do: "Vec::new::<u8>()"
  defp semantic_fragment(:method_call), do: "term.decode::<Atom>()"
  defp semantic_fragment(:struct_literal), do: "Point { x: 1 }"
  defp semantic_fragment(:local_call), do: "make_value()"
  defp semantic_fragment(:ref), do: "&value"
  defp semantic_fragment(:try), do: "fallible()?"
  defp semantic_fragment(:tuple), do: "(1, 2)"
  defp semantic_fragment(:vec_literal), do: "vec![1, 2]"
  defp semantic_fragment(:array_literal), do: "[1, 2]"
  defp semantic_fragment(:macro_repeat_expr), do: ~s|macro_repeat!(value, ",", "*")|
  defp semantic_fragment(:closure), do: "|value| value"
  defp semantic_fragment(:literal), do: "1"
  defp semantic_fragment(:byte_string), do: ~s|b"ref"|
  defp semantic_fragment(:escape_expr), do: "value.unwrap()"
  defp semantic_fragment(:token_macro), do: "quote!(None)"
  defp semantic_fragment(:macro_call), do: ~s|format!("{}", value)|
  defp semantic_fragment(:atom_value), do: "atoms::ok()"
  defp semantic_fragment(:none), do: "None"
  defp semantic_fragment(:some), do: "Some(1)"
  defp semantic_fragment(:ok), do: "Ok(())"
  defp semantic_fragment(:err), do: "Err(rustler::Error::BadArg)"
  defp semantic_fragment(:nif_raise_atom), do: "RaiseAtom"
  defp semantic_fragment(:block_expr), do: "let value = 1;"
  defp semantic_fragment(:unsafe_block), do: "unsafe {"
  defp semantic_fragment(:match), do: "match value"
  defp semantic_fragment(:if), do: "if condition"
  defp semantic_fragment(:binary_op), do: "left == right"
  defp semantic_fragment(:arm), do: "_ =>"
  defp semantic_fragment(:pat_var), do: "value =>"
  defp semantic_fragment(:pat_wildcard), do: "_ =>"
  defp semantic_fragment(:pat_path), do: "Option::None =>"
  defp semantic_fragment(:pat_literal), do: ~s|"ready" =>|
  defp semantic_fragment(:pat_none), do: "None =>"
  defp semantic_fragment(:pat_some), do: "Some(value) =>"
  defp semantic_fragment(:pat_atom_guard), do: "value if value == atoms::ok()"
  defp semantic_fragment(:pat_tuple), do: "(left, right) =>"
  defp semantic_fragment(:pat_ok), do: "Ok(value) =>"
  defp semantic_fragment(:pat_err), do: "Err(reason) =>"
  defp semantic_fragment(:pat_path_tuple), do: "Event::Click(click) =>"
  defp semantic_fragment(:pat_struct), do: "Click { name } =>"
  defp semantic_fragment(:pat_slice), do: "[head, tail @ ..] =>"
  defp semantic_fragment(_), do: ""

  def sample_for(:use), do: %AST.Use{group: {[:std], [:fmt, :io]}}
  def sample_for(:module), do: %AST.Module{name: :sample, items: [sample_for(:const)]}
  def sample_for(:const), do: %AST.Const{name: :VALUE, type: A.type_path(:u32), expr: A.lit(1)}

  def sample_for(:static),
    do: %AST.Static{
      name: :VALUE_STATIC,
      type: A.type_path(:u32),
      expr: A.lit(1)
    }

  def sample_for(:type_alias),
    do: A.type_alias(:Bytes, A.type_path(:Vec, generics: [A.type_path(:u8)]))

  def sample_for(:macro_item), do: %AST.MacroItem{source: "type Alias = u32;"}
  def sample_for(:macro_item_call), do: A.macro_item_call([:rustler, :atoms], [:ok, :error])

  def sample_for(:macro_rules) do
    A.macro_rules(
      :item_macro_sample,
      A.macro_rule(
        [
          "fn ",
          A.macro_var(:name, :ident),
          "; fields [",
          A.macro_repeat([A.macro_var(:field, :ident), ";"]),
          "]"
        ],
        [
          "fn ",
          A.macro_capture(:name),
          "() { ",
          A.macro_repeat(["let _ = stringify!(", A.macro_capture(:field), ");"]),
          " }"
        ]
      )
    )
  end

  def sample_for(:macro_rule), do: sample_for(:macro_rules)
  def sample_for(:macro_var), do: sample_for(:macro_rules)
  def sample_for(:macro_capture), do: sample_for(:macro_rules)
  def sample_for(:macro_repeat), do: sample_for(:macro_rules)

  def sample_for(:impl),
    do: %AST.Impl{
      target: A.type_path(:Sample),
      items: [function_sample(:new, A.struct_expr([:Sample], []), returns: "Self")]
    }

  def sample_for(:function), do: function_sample(:function, A.lit(1), returns: "i64")

  def sample_for(:attribute),
    do:
      function_sample(:attribute_sample, A.lit(1),
        returns: "i64",
        attrs: [A.allow_attr(:dead_code)]
      )

  def sample_for(:function_arg),
    do: %AST.Function{
      name: :function_arg_sample,
      args: [%AST.FunctionArg{name: :value, type: A.type_path(:u32)}],
      returns: "u32",
      body: [A.return(:value)]
    }

  def sample_for(:derive) do
    %AST.Struct{
      name: :DeriveSample,
      derive: [%AST.Derive{paths: [:Clone, [:serde, :Serialize]]}],
      fields: [%AST.StructField{name: :value, type: A.type_path(:u32)}]
    }
  end

  def sample_for(:struct) do
    %AST.Struct{name: :Sample, fields: [%AST.StructField{name: :value, type: A.type_path(:u32)}]}
  end

  def sample_for(:struct_field), do: sample_for(:struct)

  def sample_for(:enum) do
    %AST.Enum{name: :SampleEnum, variants: [%AST.EnumVariant{name: :Unit}]}
  end

  def sample_for(:enum_variant), do: sample_for(:enum)
  def sample_for(:type_path), do: type_sample(:type_path, A.type_path(:u32))
  def sample_for(:type_ref), do: type_sample(:type_ref, %AST.TypeRef{inner: A.type_path(:str)})

  def sample_for(:type_option),
    do: type_sample(:type_option, %AST.TypeOption{inner: A.type_path(:u32)})

  def sample_for(:type_result),
    do:
      type_sample(:type_result, %AST.TypeResult{
        ok: A.type_path(:u32),
        error: A.type_path(:String)
      })

  def sample_for(:type_nif_result),
    do: type_sample(:type_nif_result, %AST.TypeNifResult{inner: A.type_path(:u32)})

  def sample_for(:type_vec), do: type_sample(:type_vec, %AST.TypeVec{inner: A.type_path(:u8)})

  def sample_for(:type_slice),
    do: type_sample(:type_slice, %AST.TypeSlice{inner: %AST.TypeRef{inner: A.type_path(:str)}})

  def sample_for(:type_array),
    do: type_sample(:type_array, %AST.TypeArray{inner: A.type_path(:u8), size: 4})

  def sample_for(:type_tuple),
    do: type_sample(:type_tuple, %AST.TypeTuple{items: [A.type_path(:u8), A.type_path(:u16)]})

  def sample_for(:type_bare_fn) do
    type_sample(
      :type_bare_fn,
      %AST.TypeBareFn{
        args: [%AST.TypeRef{inner: A.type_path(:u8), lifetime: :a}],
        returns: A.type_path(:bool),
        lifetimes: [:a],
        unsafe: true,
        external: true,
        abi: "C"
      }
    )
  end

  def sample_for(:type_impl_trait),
    do: type_sample(:type_impl_trait, %AST.TypeImplTrait{bounds: ["Into<u32>", "Send"]})

  def sample_for(:type_raw),
    do: type_sample(:type_raw, %AST.TypeRaw{source: "std::marker::PhantomData<&'a ()>"})

  def sample_for(:type_unit), do: type_sample(:type_unit, %AST.TypeUnit{})

  def sample_for(:let),
    do:
      function_sample(:let_sample, %AST.Var{name: :value},
        body: [A.let(:value, A.lit(1)), A.return(:value)],
        returns: "i64"
      )

  def sample_for(:assign),
    do:
      function_sample(:assign_sample, A.var(:value),
        body: [A.let_mut(:value, A.lit(1)), A.assign(:value, A.lit(2)), A.return(:value)],
        returns: "i64"
      )

  def sample_for(:assign_op),
    do:
      function_sample(:assign_op_sample, A.var(:value),
        body: [A.let_mut(:value, A.lit(1)), A.assign_op(:value, :add, A.lit(2)), A.return(:value)],
        returns: "i64"
      )

  def sample_for(:let_else),
    do:
      function_sample(:let_else_sample, A.var(:value),
        body: [
          A.let_else(P.some(:value), :maybe, [A.early_return(A.lit(0))]),
          A.return(:value)
        ],
        returns: "i64"
      )

  def sample_for(:expr_stmt),
    do: function_sample(:expr_stmt, A.call(:side_effect), statement?: true)

  def sample_for(:return), do: function_sample(:return_sample, A.lit(1), returns: "i64")

  def sample_for(:early_return),
    do:
      function_sample(:early_return_sample, A.var(:value),
        body: [A.early_return(A.lit(1)), A.return(A.lit(2))],
        returns: "i64"
      )

  def sample_for(:if_let),
    do:
      function_sample(:if_let_sample, A.ok(),
        body: [
          A.if_let(P.some(:value), :maybe, [A.stmt(A.call(:use_value, [:value]))]),
          A.return(A.ok())
        ],
        returns: "NifResult<()>"
      )

  def sample_for(:for),
    do:
      function_sample(:for_sample, A.ok(),
        body: [
          A.for_(A.pat(:value), :values, [A.stmt(A.call(:use_value, [:value]))]),
          A.return(A.ok())
        ],
        returns: "NifResult<()>"
      )

  def sample_for(:loop),
    do:
      function_sample(:loop_sample, A.ok(),
        body: [A.loop([A.continue(), A.break()]), A.return(A.ok())],
        returns: "NifResult<()>"
      )

  def sample_for(:break), do: sample_for(:loop)
  def sample_for(:continue), do: sample_for(:loop)

  def sample_for(:var), do: function_sample(:var_sample, A.var(:value), returns: "i64")

  def sample_for(:path),
    do: function_sample(:path_sample, A.path([:Sample, :VALUE]), returns: "i64")

  def sample_for(:field),
    do:
      function_sample(:field_sample, %AST.Field{receiver: A.var(:opts), field: :value},
        returns: "i64"
      )

  def sample_for(:index),
    do: function_sample(:index_sample, A.index(:values, A.lit(0)), returns: "i64")

  def sample_for(:range),
    do: function_sample(:range_sample, A.range(:start, :stop), returns: "std::ops::Range<i64>")

  def sample_for(:cast), do: function_sample(:cast_sample, A.cast(:value, "f32"), returns: "f32")

  def sample_for(:unary_op),
    do: function_sample(:unary_op_sample, A.not_(:condition), returns: "bool")

  def sample_for(:path_call),
    do:
      function_sample(
        :path_call_sample,
        A.path_call([:Vec, :new], [], generics: [A.type_path(:u8)]),
        returns: "Vec<u8>"
      )

  def sample_for(:method_call),
    do:
      function_sample(
        :method_call_sample,
        A.method(:term, :decode, [], generics: [A.type_path(:Atom)]),
        returns: "NifResult<Atom>"
      )

  def sample_for(:struct_literal),
    do:
      function_sample(:struct_literal_sample, A.struct_expr([:Point], x: A.lit(1)),
        returns: "Point"
      )

  def sample_for(:local_call),
    do: function_sample(:local_call_sample, A.call(:make_value), returns: "i64")

  def sample_for(:ref), do: function_sample(:ref_sample, A.ref(:value), returns: "&i64")

  def sample_for(:try),
    do: function_sample(:try_sample, A.try(A.call(:fallible)), returns: "NifResult<()> ")

  def sample_for(:tuple),
    do:
      function_sample(:tuple_sample, %AST.Tuple{values: [A.lit(1), A.lit(2)]},
        returns: "(i64, i64)"
      )

  def sample_for(:vec_literal),
    do: function_sample(:vec_literal_sample, A.vec([A.lit(1), A.lit(2)]), returns: "Vec<i64>")

  def sample_for(:array_literal),
    do: function_sample(:array_literal_sample, A.array([A.lit(1), A.lit(2)]), returns: "[i64; 2]")

  def sample_for(:macro_repeat_expr),
    do:
      function_sample(:macro_repeat_expr_sample, %AST.MacroRepeatExpr{expr: A.var(:value)},
        returns: "TokenStream"
      )

  def sample_for(:closure),
    do:
      function_sample(:closure_sample, A.closure([:value], A.var(:value)),
        returns: "impl Fn(i64) -> i64"
      )

  def sample_for(:literal), do: function_sample(:literal_sample, A.lit(1), returns: "i64")

  def sample_for(:byte_string),
    do: function_sample(:byte_string_sample, A.byte_string("ref"), returns: "&'static [u8; 3]")

  def sample_for(:escape_expr),
    do: function_sample(:escape_expr_sample, A.escape_expr("value.unwrap()"), returns: "i64")

  def sample_for(:token_macro),
    do:
      function_sample(:token_macro_sample, A.token_macro(:quote, "None"), returns: "TokenStream")

  def sample_for(:macro_call),
    do:
      function_sample(:macro_call_sample, A.macro_call(:format, [A.lit("{}"), A.var(:value)]),
        args: [value: "i64"],
        returns: "String"
      )

  def sample_for(:atom_value),
    do: function_sample(:atom_value_sample, %AST.AtomValue{name: :ok}, returns: "Atom")

  def sample_for(:none), do: function_sample(:none_sample, A.none(), returns: "Option<i64>")

  def sample_for(:some),
    do: function_sample(:some_sample, A.some(A.lit(1)), returns: "Option<i64>")

  def sample_for(:ok), do: function_sample(:ok_sample, A.ok(), returns: "NifResult<()> ")

  def sample_for(:err),
    do: function_sample(:err_sample, A.err(A.badarg()), returns: "NifResult<()> ")

  def sample_for(:nif_raise_atom),
    do:
      function_sample(:nif_raise_atom_sample, %AST.NifRaiseAtom{name: :invalid},
        returns: "NifResult<()> "
      )

  def sample_for(:block_expr),
    do:
      function_sample(
        :block_expr_sample,
        A.block_expr([A.let(:value, A.lit(1)), A.return(:value)]),
        returns: "i64"
      )

  def sample_for(:unsafe_block),
    do:
      function_sample(
        :unsafe_block_sample,
        A.unsafe_block([A.return(A.call(:unsafe_value))]),
        returns: "i64"
      )

  def sample_for(:match), do: match_sample(:match_sample, A.wildcard())

  def sample_for(:if),
    do:
      sample_for(:match)
      |> Map.put(:name, :if_sample)
      |> Map.put(:body, [
        A.return(A.if_expr(:condition, [A.return(A.lit(1))], [A.return(A.lit(0))]))
      ])

  def sample_for(:binary_op),
    do: function_sample(:binary_op_sample, A.eq(:left, :right), returns: "bool")

  def sample_for(:arm), do: match_sample(:arm_sample, A.wildcard())
  def sample_for(:pat_var), do: match_sample(:pat_var_sample, A.pat(:value))
  def sample_for(:pat_wildcard), do: match_sample(:pat_wildcard_sample, A.wildcard())
  def sample_for(:pat_path), do: match_sample(:pat_path_sample, P.path(["Option", "None"]))
  def sample_for(:pat_literal), do: match_sample(:pat_literal_sample, P.lit("ready"))
  def sample_for(:pat_none), do: match_sample(:pat_none_sample, P.none())
  def sample_for(:pat_some), do: match_sample(:pat_some_sample, P.some(:value))

  def sample_for(:pat_atom_guard),
    do: match_sample(:pat_atom_guard_sample, %AST.PatAtomGuard{name: :ok}, args: [value: "Atom"])

  def sample_for(:pat_tuple),
    do: match_sample(:pat_tuple_sample, %AST.PatTuple{patterns: [A.pat(:left), A.pat(:right)]})

  def sample_for(:pat_ok), do: match_sample(:pat_ok_sample, P.ok(:value))
  def sample_for(:pat_err), do: match_sample(:pat_err_sample, P.err(:reason))

  def sample_for(:pat_path_tuple),
    do: match_sample(:pat_path_tuple_sample, P.path_tuple([:Event, :Click], [P.var(:click)]))

  def sample_for(:pat_struct),
    do: match_sample(:pat_struct_sample, P.struct([:Click], name: P.var(:name)))

  def sample_for(:pat_slice) do
    match_sample(
      :pat_slice_sample,
      P.slice([:head], rest: :tail)
    )
  end

  defp type_sample(name, type) do
    %AST.Const{name: String.to_atom("#{name}_VALUE"), type: type, expr: A.lit(0)}
  end

  defp function_sample(name, expr, opts) do
    body = Keyword.get(opts, :body)
    returns = Keyword.get(opts, :returns, "()")

    body =
      cond do
        body -> body
        Keyword.get(opts, :statement?) -> [A.stmt(expr), A.return(%AST.Tuple{values: []})]
        true -> [A.return(expr)]
      end

    %AST.Function{
      name: name,
      args: opts |> Keyword.get(:args, []) |> A.function_args(),
      returns: A.type(returns),
      body: body,
      attrs: Keyword.get(opts, :attrs, [])
    }
  end

  defp match_sample(name, pattern, opts \\ []) do
    function_sample(name, A.var(:value),
      args: Keyword.get(opts, :args, []),
      returns: "i64",
      body: [
        A.return(%AST.Match{
          expr: A.var(:value),
          arms: [%AST.Arm{pattern: pattern, body: [A.return(A.lit(1))]}]
        })
      ]
    )
  end
end
