defmodule RustQ.Diagnostic do
  @moduledoc """
  Structured RustQ diagnostic data for lowering/rendering failures.
  """

  defstruct [:phase, :kind, :node, :snippet, :suggestion, :details, :message]

  @type t :: %__MODULE__{
          phase: atom(),
          kind: atom(),
          node: Macro.t() | nil,
          snippet: String.t() | nil,
          suggestion: String.t() | nil,
          details: map(),
          message: String.t()
        }

  defmodule Error do
    @moduledoc """
    Exception wrapper carrying a structured `RustQ.Diagnostic` value.
    """

    defexception [:diagnostic, :message]

    @type t :: %__MODULE__{diagnostic: RustQ.Diagnostic.t(), message: String.t()}

    @impl Exception
    def exception(opts) do
      diagnostic = Keyword.fetch!(opts, :diagnostic)
      %__MODULE__{diagnostic: diagnostic, message: diagnostic.message}
    end
  end

  @doc "Raises a `RustQ.Diagnostic.Error` for a lowering failure at `node`."
  @spec lower(atom(), Macro.t(), String.t()) :: no_return()
  @spec lower(atom(), Macro.t(), String.t(), keyword()) :: no_return()
  def lower(kind, node, message, opts \\ []) do
    raise Error,
      diagnostic:
        new(:lower, kind, node, message,
          suggestion: Keyword.get(opts, :suggestion),
          details: Keyword.get(opts, :details, %{})
        )
  end

  @doc "Raises a `RustQ.Diagnostic.Error` for a `defrust` definition that cannot be built."
  @spec defrust(atom(), Macro.t(), String.t()) :: no_return()
  @spec defrust(atom(), Macro.t(), String.t(), keyword()) :: no_return()
  def defrust(kind, node, message, opts \\ []) do
    raise Error,
      diagnostic:
        new(:defrust, kind, node, message,
          suggestion: Keyword.get(opts, :suggestion),
          details: Keyword.get(opts, :details, %{})
        )
  end

  @doc "Raises a `RustQ.Diagnostic.Error` for Rust that fails to render."
  @spec render(atom(), term(), String.t()) :: no_return()
  @spec render(atom(), term(), String.t(), keyword()) :: no_return()
  def render(kind, node, message, opts \\ []) do
    raise Error,
      diagnostic:
        new(:render, kind, node, message,
          suggestion: Keyword.get(opts, :suggestion),
          details: Keyword.get(opts, :details, %{}),
          snippet: Keyword.get(opts, :snippet)
        )
  end

  @doc "Builds structured diagnostic data for extension and tooling errors."
  @spec new(atom(), atom(), Macro.t() | nil, String.t(), keyword()) :: t()
  def new(phase, kind, node, message, opts \\ []) do
    snippet = Keyword.get(opts, :snippet) || snippet(node)
    suggestion = Keyword.get(opts, :suggestion)
    details = Keyword.get(opts, :details, %{})

    %__MODULE__{
      phase: phase,
      kind: kind,
      node: node,
      snippet: snippet,
      suggestion: suggestion,
      details: details,
      message: format_message(phase, kind, message, snippet, suggestion)
    }
  end

  defp snippet(nil), do: nil

  defp snippet(node) do
    Macro.to_string(node)
  rescue
    _error in [ArgumentError, FunctionClauseError, Protocol.UndefinedError] -> inspect(node)
  end

  defp format_message(phase, kind, message, nil, nil),
    do: "#{phase} #{kind}: #{message}"

  defp format_message(phase, kind, message, snippet, nil),
    do: "#{phase} #{kind}: #{message}\n\n  #{snippet}"

  defp format_message(phase, kind, message, nil, suggestion),
    do: "#{phase} #{kind}: #{message}\n\nSuggestion: #{suggestion}"

  defp format_message(phase, kind, message, snippet, suggestion),
    do: "#{phase} #{kind}: #{message}\n\n  #{snippet}\n\nSuggestion: #{suggestion}"
end
