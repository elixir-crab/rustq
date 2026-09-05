defmodule RustQ.Native.Options do
  @moduledoc false
  alias RustQ.Meta.Options
  @native_options [:otp_app, :crate, :mode, :cargo, :crates, :build, :load]
  @spec names() :: [atom()]
  def names, do: @native_options

  def native_options!(opts, caller) when is_list(opts) do
    unknown = Keyword.keys(opts) -- (@native_options ++ Options.option_names())

    if unknown != [] do
      raise ArgumentError, "unknown RustQ.Native options: #{inspect(unknown)}"
    end

    otp_app = opts |> Keyword.get_lazy(:otp_app, &default_otp_app!/0) |> Macro.expand(caller)

    crate =
      opts
      |> Keyword.get_lazy(:crate, fn -> default_crate(caller.module) end)
      |> Macro.expand(caller)

    mode = opts |> Keyword.get_lazy(:mode, &default_mode/0) |> Macro.expand(caller)
    cargo = opts |> Keyword.get(:cargo, "cargo") |> Macro.expand(caller)
    crates = opts |> Keyword.get(:crates, []) |> Macro.expand(caller) |> normalize_crates!()
    build? = opts |> Keyword.get(:build, true) |> Macro.expand(caller)
    load? = opts |> Keyword.get(:load, build?) |> Macro.expand(caller)

    unless is_atom(otp_app) do
      raise ArgumentError, ":otp_app must be an atom"
    end

    unless mode in [:debug, :release] do
      raise ArgumentError, ":mode must be :debug or :release"
    end

    unless is_binary(cargo) do
      raise ArgumentError, ":cargo must be an executable path"
    end

    unless is_boolean(build?) do
      raise ArgumentError, ":build must be a boolean"
    end

    unless is_boolean(load?) do
      raise ArgumentError, ":load must be a boolean"
    end

    if load? and not build? do
      raise ArgumentError, ":load cannot be true when :build is false"
    end

    crate = crate |> to_string() |> normalize_crate!()

    [
      otp_app: otp_app,
      crate: crate,
      mode: mode,
      cargo: cargo,
      crates: crates,
      build: build?,
      load: load?
    ]
  end

  defp default_otp_app! do
    Mix.Project.config()[:app] ||
      raise ArgumentError, "RustQ.Native could not infer :otp_app from the current Mix project"
  end

  defp default_crate(module) do
    module |> Module.split() |> Enum.map_join("_", &Macro.underscore/1)
  end

  defp default_mode do
    if Mix.env() == :prod do
      :release
    else
      :debug
    end
  end

  defp normalize_crate!(crate) do
    crate = String.replace(crate, "-", "_")

    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, crate) do
      crate
    else
      raise ArgumentError, "invalid generated Cargo crate name #{inspect(crate)}"
    end
  end

  defp normalize_crates!(crates) when is_list(crates) do
    Enum.map(crates, fn
      {package, version} when (is_atom(package) or is_binary(package)) and is_binary(version) ->
        {to_string(package), version}

      {package, spec} when (is_atom(package) or is_binary(package)) and is_list(spec) ->
        {to_string(package), spec}

      other ->
        raise ArgumentError,
              ":crates must be a keyword/list of package names to version strings or options, got: #{inspect(other)}"
    end)
  end

  defp normalize_crates!(other) do
    raise ArgumentError, ":crates must be a keyword list, got: #{inspect(other)}"
  end
end
