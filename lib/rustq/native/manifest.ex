defmodule RustQ.Native.Manifest do
  @moduledoc false

  @spec encode!(String.t(), [{String.t() | atom(), String.t() | keyword()}]) :: String.t()
  def encode!(crate, crates) do
    dependencies =
      Enum.reduce(crates, %{"rustler" => "0.37"}, fn {package, spec}, dependencies ->
        package = to_string(package)

        unless Regex.match?(~r/^[A-Za-z0-9_-]+$/, package) do
          raise ArgumentError, "invalid Cargo dependency name #{inspect(package)}"
        end

        if Map.has_key?(dependencies, package) do
          raise ArgumentError, "duplicate Cargo dependency #{inspect(package)}"
        end

        Map.put(dependencies, package, dependency!(spec))
      end)

    TomlElixir.encode!(%{
      "package" => %{
        "name" => crate,
        "version" => "0.1.0",
        "edition" => "2021",
        "publish" => false
      },
      "lib" => %{"name" => crate, "crate-type" => ["cdylib"]},
      "dependencies" => dependencies
    })
  end

  defp dependency!(version) when is_binary(version), do: version

  defp dependency!(options) when is_list(options) do
    Enum.reduce(options, %{}, fn option, entries ->
      {key, value} = dependency_option!(option)

      if Map.has_key?(entries, key) do
        raise ArgumentError, "duplicate Cargo dependency option #{inspect(key)}"
      end

      Map.put(entries, key, value)
    end)
  end

  defp dependency!(other),
    do: raise(ArgumentError, "unsupported Cargo dependency #{inspect(other)}")

  defp dependency_option!({key, value})
       when key in [:version, :git, :branch, :tag, :rev] and is_binary(value),
       do: {Atom.to_string(key), value}

  defp dependency_option!({:path, value}) when is_binary(value),
    do: {"path", Path.expand(value)}

  defp dependency_option!({:default_features, value}) when is_boolean(value),
    do: {"default-features", value}

  defp dependency_option!({:features, values}) when is_list(values) do
    unless Enum.all?(values, &is_binary/1) do
      raise ArgumentError, "Cargo dependency features must be strings"
    end

    {"features", values}
  end

  defp dependency_option!(other),
    do: raise(ArgumentError, "unsupported Cargo dependency option #{inspect(other)}")
end
