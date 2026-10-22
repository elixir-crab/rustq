defmodule RustQ.Syn.Doc do
  @moduledoc """
  Turns Rust doc comments read by `RustQ.Syn` into Markdown for Elixir docs.
  """

  @doc """
  Renders Rust doc comment lines as Markdown suitable for consumer docs.

  This keeps the transformation structural and conservative: it only normalizes
  Rust intra-doc code links into Markdown code spans and joins lines.
  """
  @spec markdown([String.t()]) :: String.t()
  def markdown(lines) when is_list(lines) do
    Enum.map_join(lines, "\n", &line/1)
  end

  @doc "Normalizes one Rust doc line for Markdown output."
  @spec line(String.t()) :: String.t()
  def line(line) when is_binary(line), do: normalize_links(line)

  defp normalize_links(line) do
    case :binary.match(line, "[`") do
      :nomatch -> line
      {start, _length} -> normalize_link_at(line, start)
    end
  end

  defp normalize_link_at(line, start) do
    prefix = binary_part(line, 0, start)
    rest = binary_part(line, start + 2, byte_size(line) - start - 2)
    {target, rest} = strip_crate_prefix(rest)

    case :binary.match(rest, "`]") do
      {finish, _length} when finish > 0 ->
        link = binary_part(target, 0, finish)
        suffix = binary_part(rest, finish + 2, byte_size(rest) - finish - 2)
        prefix <> "`" <> link <> "`" <> normalize_links(suffix)

      _not_a_link ->
        prefix <> "[`" <> normalize_links(rest)
    end
  end

  defp strip_crate_prefix("crate::" <> rest), do: {rest, rest}
  defp strip_crate_prefix(rest), do: {rest, rest}
end
