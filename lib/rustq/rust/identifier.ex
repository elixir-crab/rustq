defmodule RustQ.Rust.Identifier do
  @moduledoc """
  Safe conversion of finite generator names into Rust identifier atoms.

  RustQ AST node names are represented as atoms for native decoding. Use
  `atom!/1` when a generator derives a Rust identifier from bounded structural
  metadata rather than calling `String.to_atom/1` directly.
  """

  @max_bytes 128

  @doc "Returns a Rust identifier atom, rejecting invalid or oversized names."
  @spec atom!(atom() | String.t()) :: atom()
  def atom!(value) when is_atom(value) do
    if value |> Atom.to_string() |> valid_identifier?() do
      value
    else
      raise ArgumentError, "unsafe Rust identifier: #{inspect(value)}"
    end
  end

  def atom!(value) when is_binary(value) do
    if valid_identifier?(value) do
      :erlang.binary_to_atom(value, :utf8)
    else
      raise ArgumentError, "unsafe Rust identifier: #{inspect(value)}"
    end
  end

  @doc """
  Returns whether a string is a Rust identifier accepted by `atom!/1`. An Elixir predicate
  name such as `live?` is accepted; rendering drops its `?`.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(<<first, rest::binary>>) when first in ?A..?Z or first in ?a..?z,
    do: valid_tail?(rest)

  def valid?(<<"_", rest::binary>>), do: valid_tail?(rest)
  def valid?(""), do: false

  defp valid_identifier?(value), do: byte_size(value) <= @max_bytes and valid?(value)

  defp valid_tail?(<<>>), do: true
  # An Elixir predicate's `?`, which Rust names drop.
  defp valid_tail?("?"), do: true

  defp valid_tail?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9,
       do: valid_tail?(rest)

  defp valid_tail?(<<"_", rest::binary>>), do: valid_tail?(rest)
  defp valid_tail?(_invalid), do: false
end
