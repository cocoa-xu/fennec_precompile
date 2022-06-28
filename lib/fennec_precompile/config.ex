defmodule FennecPrecompile.Config do
  @moduledoc false

  # This is an internal struct to represent valid config options.
  defstruct [
    :nif_filename,
    :module,
    :base_url,
    :version,
    :base_cache_dir,
    :load_data,
    :targets
  ]

  @default_targets ~w(
    x86_64-macos
    x86_64-linux-gnu
    x86_64-linux-musl
    x86_64-windows-gnu
    aarch64-macos
    aarch64-linux-gnu
    aarch64-linux-musl
    riscv64-linux-musl
  )

  def default_targets, do: @default_targets

  def new(opts) do
    version = Keyword.fetch!(opts, :version)
    base_url = opts |> Keyword.fetch!(:base_url) |> validate_base_url!()
    targets = opts |> Keyword.get(:targets, @default_targets) |> validate_targets!()

    %__MODULE__{
      base_url: base_url,
      module: Keyword.fetch!(opts, :module),
      version: version,
      nif_filename: opts[:nif_filename] || to_string(Mix.Project.config()[:app]),
      load_data: opts[:load_data] || 0,
      base_cache_dir: opts[:base_cache_dir],
      targets: targets
    }
  end

  defp validate_base_url!(nil), do: raise_for_nil_field_value(:base_url)

  defp validate_base_url!(base_url) do
    case :uri_string.parse(base_url) do
      %{} ->
        base_url

      {:error, :invalid_uri, error} ->
        raise "`:base_url` for `FennecPrecompile` is invalid: #{inspect(to_string(error))}"
    end
  end

  defp validate_targets!(nil), do: raise_for_nil_field_value(:targets)

  defp validate_targets!(targets) do
    if is_list(targets) do
      targets
    else
      raise "`:targets` is required to be a list of targets supported by Zig"
    end
  end

  defp raise_for_nil_field_value(field) do
    raise "`#{inspect(field)}` is required for `FennecPrecompile`"
  end
end
