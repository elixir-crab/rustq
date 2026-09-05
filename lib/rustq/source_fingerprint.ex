defmodule RustQ.SourceFingerprint do
  @moduledoc false

  @spec file(Path.t()) :: tuple()
  def file(path) do
    case File.read(path) do
      {:ok, contents} -> {path, :sha256, :crypto.hash(:sha256, contents)}
      {:error, reason} -> {path, :missing, reason}
    end
  end
end
