defmodule RustQ.Template do
  @moduledoc """
  Parsed Rust template plus pending substitutions.
  """

  defstruct [:source, :filename, bindings: [], splices: []]

  @type t :: %__MODULE__{
          source: String.t(),
          filename: String.t(),
          bindings: keyword(),
          splices: [{atom(), term()}]
        }

  @include_marker "__rq_include!"

  @doc "Expands `__rq_include!` markers when the `:include_dir` option is given."
  def maybe_expand_includes(source, filename, opts) do
    if Keyword.has_key?(opts, :include_dir) do
      expand_includes(source, filename, opts)
    else
      {:ok, IO.iodata_to_binary(source)}
    end
  end

  @doc """
  Replaces each `__rq_include!(\"path\")` marker with the file it names, relative to
  `:include_dir` or the template's directory, rejecting include cycles.
  """
  def expand_includes(source, filename, opts) do
    include_dir = Keyword.get(opts, :include_dir, Path.dirname(filename))

    source
    |> IO.iodata_to_binary()
    |> expand_includes_from(filename, include_dir, [Path.expand(filename)])
  end

  @doc "Prepends the `:preamble` option to rendered code."
  def with_preamble(code, opts) do
    case Keyword.get(opts, :preamble, "") do
      nil -> code
      "" -> code
      preamble -> IO.iodata_to_binary([preamble, code])
    end
  end

  @doc "Formats rendered code with `rustfmt`, or the command the `:rustfmt` option names."
  def maybe_rustfmt(code, opts, filename) do
    case Keyword.get(opts, :rustfmt, false) do
      false ->
        {:ok, code}

      true ->
        rustfmt(code, filename, "rustfmt")

      command when is_binary(command) ->
        rustfmt(code, filename, command)
    end
  end

  @doc "Turns native template errors into maps with atom fields, tagged with the template's file."
  def normalize_errors(errors, filename) do
    Enum.map(errors, fn error ->
      error
      |> Map.update(:type, nil, &string_to_atom/1)
      |> Map.update(:context, nil, &string_to_atom/1)
      |> Map.update(:name, nil, &string_to_atom/1)
      |> Map.put(:filename, filename)
    end)
  end

  defp expand_includes_from(source, filename, include_dir, stack) do
    case next_include(source) do
      nil ->
        {:ok, source}

      {start, length, relative_path} ->
        expand_next_include(source, filename, include_dir, stack, start, length, relative_path)
    end
  end

  defp expand_next_include(source, filename, include_dir, stack, start, length, relative_path) do
    include_path = Path.expand(relative_path, include_dir)

    if include_path in stack do
      include_error(filename, "cyclic RustQ include: #{include_path}", stack ++ [include_path])
    else
      replace_include(source, filename, include_dir, stack, start, length, include_path)
    end
  end

  defp next_include(source), do: next_include(source, 0)

  defp next_include(source, offset) when offset < byte_size(source) do
    case :binary.match(source, @include_marker, scope: {offset, byte_size(source) - offset}) do
      :nomatch -> nil
      {start, _length} -> parse_include(source, start) || next_include(source, start + 1)
    end
  end

  defp next_include(_source, _offset), do: nil

  defp parse_include(source, start) do
    marker_end = start + byte_size(@include_marker)

    with {:ok, rest} <- take_symbol(source, marker_end, ?(),
         {:ok, rest} <- skip_whitespace(source, rest),
         {:ok, path_start} <- take_symbol(source, rest, ?"),
         {path_end, _quote_length} <-
           :binary.match(source, "\"", scope: {path_start, byte_size(source) - path_start}),
         {:ok, rest} <- skip_whitespace(source, path_end + 1),
         {:ok, rest} <- take_symbol(source, rest, ?)),
         {:ok, rest} <- skip_whitespace(source, rest),
         {:ok, finish} <- take_symbol(source, rest, ?;) do
      {start, finish - start, binary_part(source, path_start, path_end - path_start)}
    else
      _invalid_include -> nil
    end
  end

  defp take_symbol(source, offset, symbol) do
    with {:ok, offset} <- skip_whitespace(source, offset),
         <<^symbol, _rest::binary>> <- binary_part(source, offset, byte_size(source) - offset) do
      {:ok, offset + 1}
    else
      _missing_symbol -> :error
    end
  end

  defp skip_whitespace(source, offset) do
    case binary_part(source, offset, byte_size(source) - offset) do
      <<char, _rest::binary>> when char in [32, 9, 10, 13] -> skip_whitespace(source, offset + 1)
      _rest -> {:ok, offset}
    end
  end

  defp replace_include(source, filename, include_dir, stack, start, length, include_path) do
    with {:ok, included} <- read_include(include_path, filename),
         {:ok, expanded} <-
           expand_includes_from(
             included,
             include_path,
             Path.dirname(include_path),
             stack ++ [include_path]
           ) do
      source =
        binary_part(source, 0, start) <>
          expanded <>
          binary_part(source, start + length, byte_size(source) - start - length)

      expand_includes_from(source, filename, include_dir, stack)
    end
  end

  defp read_include(path, filename) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        include_error(
          filename,
          "cannot read RustQ include #{path}: #{:file.format_error(reason)}",
          [Path.expand(filename), path]
        )
    end
  end

  defp include_error(filename, message, include_stack) do
    {:error,
     [
       %{
         type: :include_error,
         context: :include,
         message: message,
         filename: filename,
         include_stack: Enum.map(include_stack, &Path.expand/1)
       }
     ]}
  end

  defp rustfmt_temp_path(filename) do
    extension =
      filename
      |> Path.extname()
      |> case do
        "" -> ".rs"
        extension -> extension
      end

    Path.join(
      System.tmp_dir!(),
      "rustq-rustfmt-#{System.unique_integer([:positive])}#{extension}"
    )
  end

  defp rustfmt(code, filename, command) do
    path = rustfmt_temp_path(filename)
    File.write!(path, code)

    case System.cmd(command, ["--emit", "stdout", "--quiet", path], stderr_to_stdout: true) do
      {formatted, 0} ->
        File.rm(path)
        {:ok, formatted}

      {output, status} ->
        File.rm(path)

        {:error,
         [
           %{
             type: :rustfmt_error,
             context: :rustfmt,
             message: "#{command} failed",
             filename: filename,
             command: command,
             status: status,
             output: output
           }
         ]}
    end
  rescue
    error in ErlangError ->
      {:error,
       [
         %{
           type: :rustfmt_error,
           context: :rustfmt,
           message: "cannot run #{command}",
           filename: filename,
           command: command,
           reason: error.original
         }
       ]}
  end

  defp string_to_atom(nil), do: nil
  defp string_to_atom(value) when is_atom(value), do: value

  defp string_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
