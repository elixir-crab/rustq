defmodule RustQ.Meta.TypespecMatrixTest do
  @moduledoc """
  Passes every typespec form through a NIF boundary, as `@spec echo(form) :: form`, and checks
  the Rust signature RustQ generates. A form RustQ cannot map must be rejected with a
  diagnostic rather than become a Rust type named after it.
  """

  use ExUnit.Case, async: true

  # Each form with the Rust argument and return types its `echo` NIF takes and gives, or
  # `:unsupported` for a form RustQ rejects.
  @matrix [
    {quote(do: integer()), {"i64", "i64"}},
    {quote(do: float()), {"f64", "f64"}},
    {quote(do: number()), {"f64", "f64"}},
    {quote(do: boolean()), {"bool", "bool"}},
    {quote(do: String.t()), {"String", "String"}},
    {quote(do: binary()), {"Binary<'a>", "Vec<u8>"}},
    {quote(do: atom()), {"Atom", "Atom"}},
    {quote(do: term()), {"Term<'a>", "Term<'a>"}},
    {quote(do: any()), {"Term<'a>", "Term<'a>"}},
    {quote(do: :ok), {"Atom", "Atom"}},
    {quote(do: :small | :large), {"Atom", "Atom"}},
    {quote(do: integer() | nil), {"Option<i64>", "Option<i64>"}},
    {quote(do: nil | String.t()), {"Option<String>", "Option<String>"}},
    {quote(do: {:ok, integer()} | {:error, String.t()}),
     {"Result<i64, String>", "EchoNifResult"}},
    {quote(do: [integer()]), {"Vec<i64>", "Vec<i64>"}},
    {quote(do: list(integer())), {"Vec<i64>", "Vec<i64>"}},
    {quote(do: nonempty_list(integer())), {"Vec<i64>", "Vec<i64>"}},
    {quote(do: {integer(), float()}), {"(i64, f64)", "(i64, f64)"}},
    {quote(do: {integer(), String.t(), boolean()}),
     {"(i64, String, bool)", "(i64, String, bool)"}},
    {quote(do: [{atom(), integer()}]), {"Vec<(Atom, i64)>", "Vec<(Atom, i64)>"}},
    {quote(do: %{String.t() => integer()}), {"HashMap<String, i64>", "HashMap<String, i64>"}},
    {quote(do: HashMap.t(String.t(), integer())),
     {"HashMap<String, i64>", "HashMap<String, i64>"}},
    {quote(do: R.u8()), {"u8", "u8"}},
    {quote(do: R.u32()), {"u32", "u32"}},
    {quote(do: R.i64()), {"i64", "i64"}},
    {quote(do: R.usize()), {"usize", "usize"}},
    {quote(do: R.f32()), {"f32", "f32"}},
    {quote(do: R.f64()), {"f64", "f64"}},
    {quote(do: R.bool()), {"bool", "bool"}},
    {quote(do: R.term()), {"Term<'a>", "Term<'a>"}},
    {quote(do: R.atom()), {"Atom", "Atom"}},
    {quote(do: R.vec(integer())), {"Vec<i64>", "Vec<i64>"}},
    {quote(do: R.option(integer())), {"Option<i64>", "Option<i64>"}},
    {quote(do: R.result(integer(), String.t())), {"Result<i64, String>", "EchoNifResult"}},
    {quote(do: point()), {"Point", "Point"}},
    {quote(do: [point()]), {"Vec<Point>", "Vec<Point>"}},
    {quote(do: point() | nil), {"Option<Point>", "Option<Point>"}},
    {quote(do: shape()), {"Shape", "Shape"}},
    {quote(do: mode()), {"Mode", "Mode"}},
    {quote(do: nil), :unsupported},
    {quote(do: 1), :unsupported},
    {quote(do: 1..10), :unsupported},
    {quote(do: non_neg_integer()), :unsupported},
    {quote(do: pos_integer()), :unsupported},
    {quote(do: byte()), :unsupported},
    {quote(do: char()), :unsupported},
    {quote(do: map()), :unsupported},
    {quote(do: keyword()), :unsupported},
    {quote(do: charlist()), :unsupported},
    {quote(do: iodata()), :unsupported},
    {quote(do: pid()), :unsupported},
    {quote(do: reference()), :unsupported},
    {quote(do: tuple()), :unsupported},
    {quote(do: list()), :unsupported},
    {quote(do: struct()), :unsupported}
  ]

  test "maps every typespec form to its Rust type, or rejects it" do
    mismatches =
      for {form, expected} <- @matrix,
          actual = echo_signature(form),
          actual != expected,
          do: {Macro.to_string(form), expected: expected, actual: actual}

    assert mismatches == []
  end

  test "rejects a type declared twice instead of following the later one" do
    module = Module.concat(__MODULE__, "Duplicate#{System.unique_integer([:positive])}")

    error =
      assert_raise RustQ.Diagnostic.Error, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use RustQ.Meta
          @type point :: %{required(:x) => float()}
          @type point :: %{required(:y) => integer()}
          @spec y(point()) :: integer()
          defrust y(point), do: point.y
        end
        """)
      end

    assert %RustQ.Diagnostic{
             kind: :duplicate_type,
             details: %{type: {:point, 0}, lines: [first, second]}
           } = error.diagnostic

    assert {first, second} == {3, 4}
    assert error.message =~ "at lines 3 and 4"
  end

  defp echo_signature(form) do
    module =
      compile(fn module ->
        quote do
          defmodule unquote(module) do
            use RustQ.Native, build: false, load: false
            alias RustQ.Type, as: R

            @type point :: %{required(:x) => float(), required(:y) => float()}
            @type shape :: R.enum(circle: [float()], empty: [])
            @type mode :: :fast | :slow

            @spec echo(unquote(form)) :: unquote(form)
            defnif(echo(value), do: value)
          end
        end
      end)

    source = RustQ.Native.source(module)
    assert RustQ.valid?(source, "typespec_matrix.rs")

    [_signature, arg, return] =
      Regex.run(~r/fn echo(?:<'a>)?\(value: (.+)\) -> (.+) \{/, source)

    {arg, return}
  rescue
    error in RustQ.Diagnostic.Error ->
      if Exception.message(error) =~ "unsupported_type",
        do: :unsupported,
        else: reraise(error, __STACKTRACE__)
  end

  defp compile(module_ast) do
    module = Module.concat(__MODULE__, "M#{System.unique_integer([:positive])}")
    Code.compile_quoted(module_ast.(module))
    module
  end
end
