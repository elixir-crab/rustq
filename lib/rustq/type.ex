defmodule RustQ.Type do
  @moduledoc """
  Built-in Rust/Rustler type vocabulary for `RustQ.Meta.defrust/2` specs.

  Prefer ordinary Elixir types when they fit. `RustQ.Meta` maps built-ins such
  as `atom()`, `term()`, `boolean()`, `integer()`, `float()`, and `binary()` to
  Rust/Rustler types. Use ordinary remote types for external Rust paths where
  possible: `SkiaSafe.Canvas.t()` renders as `skia_safe::Canvas`, and
  `GeneratedOpts.OvalOpts.t(R.lifetime(:a))` renders as
  `generated_opts::OvalOpts<'a>`. Use this module where Rust needs extra
  precision or syntax that Elixir types cannot express cleanly: fixed-width
  numbers, enum intent markers, references, lifetimes, slices, `NifResult`,
  `Vec`, generated resources, and unit.

      alias RustQ.Type, as: R

      @spec draw(R.ref(SkiaSafe.Canvas.t()), R.f32(), R.f32()) :: R.nif_result(R.unit())
      defrust draw(canvas, x, y) do
        canvas.translate({x, y})
        :ok
      end

      @spec decode_mode(atom()) :: R.nif_result(Mode.t())
      defrust decode_mode(atom) do
        # atom() maps to Rustler Atom
      end

  The functions with matching names are marker helpers for non-typespec macro
  contexts and for the reserved built-in names (`R.atom()`, `R.bool()`,
  `R.term()`). They are not runtime APIs.
  """

  @typedoc "Rust `()`; represented as `:ok`/unit-ish data in Elixir specs."
  @type unit :: :ok

  # `bool`, `atom`, and `term` are built-in Elixir type names and cannot be
  # redefined as remote types. RustQ still accepts `R.bool()`, `R.atom()`, and
  # `R.term()` in defrust specs by reading the marker call AST.
  @typedoc "Rust `i8`."
  @type i8 :: integer()

  @typedoc "Rust `i16`."
  @type i16 :: integer()

  @typedoc "Rust `i32`."
  @type i32 :: integer()

  @typedoc "Rust `i64`."
  @type i64 :: integer()

  @typedoc "Rust `isize`."
  @type isize :: integer()

  @typedoc "Rust `u8`."
  @type u8 :: 0..255

  @typedoc "Rust `u16`."
  @type u16 :: non_neg_integer()

  @typedoc "Rust `u32`."
  @type u32 :: non_neg_integer()

  @typedoc "Rust `u64`."
  @type u64 :: non_neg_integer()

  @typedoc "Rust `usize`."
  @type usize :: non_neg_integer()

  @typedoc "Rust `f32`."
  @type f32 :: float()

  @typedoc "Rust `f64`."
  @type f64 :: float()

  @typedoc "Rust string slice `&str`."
  @type str :: binary()

  @typedoc "Rust shared reference `&T`."
  @type ref(t) :: t

  @typedoc "Rust mutable reference `&mut T`."
  @type mut_ref(t) :: t

  @typedoc "Rust `Option<T>`."
  @type option(t) :: nil | t

  @typedoc "Rust `Result<Ok, Error>`."
  @type result(ok, error) :: {:ok, ok} | {:error, error}

  @typedoc "Rustler `NifResult<T>`."
  @type nif_result(t) :: {:ok, t} | {:error, nif_error()}

  @typedoc "Rust `Vec<T>`."
  @type vec(t) :: [t]

  @typedoc "Rustler `ResourceArc<T>` boundary with RustQ-generated resource registration."
  @type resource(t) :: reference() | t

  @typedoc "Rustler NIF error marker."
  @type nif_error :: atom()

  @typedoc "Low-level explicit Rust path marker. Prefer ordinary remote types such as `GeneratedOpts.OvalOpts.t(...)` when possible."
  @type path(parts) :: {parts, term()}

  @typedoc "Low-level explicit Rust path marker with options such as `R.lifetime(:a)`. Prefer ordinary remote types when possible."
  @type path(parts, opts) :: {parts, opts, term()}

  @typedoc """
  Opaque Rust callable (`impl Fn(...) -> ...` by default).

  Use an ordinary Elixir function signature. Options are `kind: :fn | :fn_mut |
  :fn_once`, `traits: [Send.t(), ...]`, and `lifetime: R.lifetime(:static)`.
  For example: `R.impl((-> R.usize()), traits: [Send.t()], lifetime: R.lifetime(:static))`.
  Capture ownership is separate: use `move(fn ... end)` in the function body.
  This is a native type marker, not a BEAM-callable closure or a Rustler codec.
  """
  @type impl(signature) :: signature
  @type impl(signature, options) :: {signature, options}

  @typedoc "Rust lifetime marker for external remote types and low-level `R.path/2`."
  @type lifetime(name) :: {name, term()}

  @typedoc "Rust slice reference `&[T]`."
  @type slice(t) :: {t, term()}

  @typedoc "Raw Rust type fragment marker for syntax Elixir typespecs cannot model. Prefer structural markers such as `R.slice/1` when possible."
  @type raw(name) :: {name, term()}

  @typedoc "Enum intent marker for domain-specific descriptor resolution, or explicit Rust enum variants when used in a type alias."
  @type enum(name_or_variants) :: atom() | {name_or_variants}

  @spec atom() :: no_return()
  def atom, do: type_only!()

  @spec bool() :: no_return()
  def bool, do: type_only!()

  @spec f32() :: no_return()
  def f32, do: type_only!()

  @spec f64() :: no_return()
  def f64, do: type_only!()

  @spec i8() :: no_return()
  def i8, do: type_only!()

  @spec i16() :: no_return()
  def i16, do: type_only!()

  @spec i32() :: no_return()
  def i32, do: type_only!()

  @spec i64() :: no_return()
  def i64, do: type_only!()

  @spec isize() :: no_return()
  def isize, do: type_only!()

  @spec str() :: no_return()
  def str, do: type_only!()

  @spec term() :: no_return()
  def term, do: type_only!()

  @spec u8() :: no_return()
  def u8, do: type_only!()

  @spec u16() :: no_return()
  def u16, do: type_only!()

  @spec u32() :: no_return()
  def u32, do: type_only!()

  @spec u64() :: no_return()
  def u64, do: type_only!()

  @spec usize() :: no_return()
  def usize, do: type_only!()

  @spec unit() :: no_return()
  def unit, do: type_only!()

  @spec path(term()) :: no_return()
  def path(_parts), do: type_only!()

  @spec path(term(), term()) :: no_return()
  def path(_parts, _opts), do: type_only!()

  @spec impl(term()) :: no_return()
  def impl(_signature), do: type_only!()

  @spec impl(term(), term()) :: no_return()
  def impl(_signature, _options), do: type_only!()

  @spec lifetime(term()) :: no_return()
  def lifetime(_name), do: type_only!()

  @spec slice(term()) :: no_return()
  def slice(_type), do: type_only!()

  @spec raw(term()) :: no_return()
  def raw(_name), do: type_only!()

  @spec enum(term()) :: no_return()
  def enum(_name_or_variants), do: type_only!()

  @spec ref(term()) :: no_return()
  def ref(_type), do: type_only!()

  @spec mut_ref(term()) :: no_return()
  def mut_ref(_type), do: type_only!()

  @spec option(term()) :: no_return()
  def option(_type), do: type_only!()

  @spec vec(term()) :: no_return()
  def vec(_type), do: type_only!()

  @spec resource(term()) :: no_return()
  def resource(_type), do: type_only!()

  @spec result(term(), term()) :: no_return()
  def result(_ok, _error), do: type_only!()

  @spec nif_result(term()) :: no_return()
  def nif_result(_type), do: type_only!()

  defp type_only! do
    raise "RustQ.Type functions are typespec markers for RustQ.Meta; they are not runtime functions"
  end
end
