defmodule FennecPrecompile.Config do
  @moduledoc false

  # This is an internal struct to represent valid config options.
  defstruct [
    :app,
    :version,
    :base_url,
    :nif_filename,
    :nif_version,
    :force_build,
    :force_build_args,
    :force_build_using_zig,
    :targets
  ]

  @default_targets_macos ~w(
    x86_64-macos
    x86_64-linux-gnu
    x86_64-linux-musl
    x86_64-windows-gnu
    aarch64-macos
    aarch64-linux-gnu
    aarch64-linux-musl
    riscv64-linux-musl
  )

  @default_targets_linux ~w(
    x86_64-linux-gnu
    x86_64-linux-musl
    x86_64-windows-gnu
    aarch64-linux-gnu
    aarch64-linux-musl
    riscv64-linux-musl
  )

  def default_targets_macos, do: @default_targets_macos
  def default_targets_linux, do: @default_targets_linux
  def default_targets, do: Enum.uniq(default_targets_macos() ++ default_targets_linux())

  def new(opts) do
    app = opts |> Keyword.fetch!(:app)
    version = Keyword.fetch!(opts, :version)
    base_url = opts |> Keyword.fetch!(:fennec_base_url) |> validate_base_url!()
    targets = opts |> Keyword.get(:fennec_targets, default_targets()) |> validate_targets!()
    nif_version = opts |> Keyword.get(:fennec_nif_version, to_string(:erlang.system_info(:nif_version)))

    %__MODULE__{
      app: app,
      base_url: base_url,
      version: version,
      nif_filename: opts[:fennec_nif_filename] || to_string(app),
      nif_version: nif_version,
      targets: targets,
      force_build: pre_release?(version) or Keyword.get(opts, :fennec_force_build, false),
      force_build_args: opts[:fennec_force_build_args] || [],
      force_build_using_zig: opts[:fennec_force_build_using_zig] || false
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

  defp pre_release?(version) do
    "dev" in Version.parse!(version).pre
  end
end
