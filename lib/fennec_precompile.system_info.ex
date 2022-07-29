defmodule FennecPrecompile.SystemInfo do
  @available_nif_versions ~w(2.14 2.15 2.16)

  @doc """
  Returns the target triple for download or compile and load.

  This function is translating and adding more info to the system
  architecture returned by Elixir/Erlang to one used by `convention`.

  ## Examples

      iex> FennecPrecompile.SystemInfo.target(:rust)
      {:ok, "aarch64-apple-darwin"}
      iex> FennecPrecompile.SystemInfo.target(:zig)
      {:ok, "aarch64-macos"}

  """
  def target(convention, opts \\ []) do
    config = opts[:target_config] || target_config()

    normalize_target_system =
      opts[:normalize_target_system] ||
        (&FennecPrecompile.SystemInfo.normalize_target_system(&1, &2))

    available_targets = opts[:available_targets] || default_targets(convention)
    available_nif_versions = opts[:available_nif_versions] || @available_nif_versions

    arch_os =
      case config.os_type do
        {:unix, _} ->
          config.target_system
          |> normalize_target_system.(convention)
          |> system_architecture_to_string()

        {:win32, _} ->
          existing_target =
            config.target_system
            |> system_architecture_to_string()

          # For when someone is setting "TARGET_*" vars on Windows
          if existing_target in available_targets do
            existing_target
          else
            # 32 or 64 bits
            arch =
              case convention do
                :rust ->
                  case config.word_size do
                    4 -> "i686"
                    8 -> "x86_64"
                    _ -> "unknown"
                  end

                :zig ->
                  case config.word_size do
                    4 -> "x86"
                    8 -> "x64"
                    _ -> "unknown"
                  end
              end

            config.target_system
            |> Map.put_new(:arch, arch)
            |> Map.put_new(:os, "windows")
            |> Map.put_new(:abi, "msvc")
            |> system_architecture_to_string()
          end
      end

    cond do
      arch_os not in available_targets ->
        {:error,
         "precompiled NIF is not available for this target: #{inspect(arch_os)}.\n" <>
           "The available targets are:\n - #{Enum.join(available_targets, "\n - ")}"}

      config.nif_version not in available_nif_versions ->
        {:error,
         "precompiled NIF is not available for this NIF version: #{inspect(config.nif_version)}.\n" <>
           "The available NIF versions are:\n - #{Enum.join(available_nif_versions, "\n - ")}"}

      true ->
        {:ok, arch_os}
    end
  end

  @doc """
  Get a config map for current node.

  ## Parameters

    - `allow_env_var_override`.

      Defaults to `true`.

      Indicating whether allows environment variables to override
      values for `:arch`, `:vendor`, `:os` and `:abi`.

      The following environment variables will be tested and replace
      correspondingly if not empty.

      | Environment Variable | Maps to Key |
      |----------------------|-------------|
      | `TARGET_ARCH`        | `:arch`     |
      | `TARGET_VENDOR`      | `:vendor`   |
      | `TARGET_OS  `        | `:os`       |
      | `TARGET_ABI`         | `:abi`      |

  ## Return

  The map includes 4 keys:
    - `:os_type`. Value returned from `:os.type()`.
    - `:target_system`.
    - `:word_size`. Value returned from `:erlang.system_info(:wordsize)`.
    - `:nif_version`. Exact or compatible nif version for current node.

  ## Example

      iex> FennecPrecompile.SystemInfo.target_config(false)
      %{
        nif_version: "2.16",
        os_type: {:unix, :darwin},
        target_system: %{abi: "darwin21.4.0", arch: "aarch64", os: "apple"},
        word_size: 8
      }

      iex> System.put_env("TARGET_ARCH", "x86_64")
      :ok
      iex> FennecPrecompile.SystemInfo.target_config(true)
      %{
        nif_version: "2.16",
        os_type: {:unix, :darwin},
        target_system: %{abi: "darwin21.4.0", arch: "x86_64", os: "apple"},
        word_size: 8
      }

  """
  @spec target_config(boolean()) :: %{
          os_type: {:unix, atom} | {:win32, atom},
          target_system: %{},
          word_size: 4 | 8,
          nif_version: String.t()
        }
  def target_config(allow_env_var_override \\ true) do
    current_nif_version = current_nif_version()

    override =
      if allow_env_var_override do
        &maybe_override_with_env_vars(&1)
      else
        & &1
      end

    nif_version =
      case find_compatible_nif_version(current_nif_version, @available_nif_versions) do
        {:ok, vsn} ->
          vsn

        :error ->
          # In case of error, use the current so we can tell the user.
          current_nif_version
      end

    current_system_arch = system_architecture()

    %{
      os_type: :os.type(),
      target_system: override.(current_system_arch),
      word_size: :erlang.system_info(:wordsize),
      nif_version: nif_version
    }
  end

  @doc """
  Normalize the given target system map accordingly

  `convention` can be `:rust` or `:zig`

  """
  def normalize_target_system(target_system, convention)

  def normalize_target_system(target_system, :rust) do
    cond do
      target_system.abi =~ "darwin" ->
        arch = with "arm" <- target_system.arch, do: "aarch64"

        %{target_system | arch: arch, os: "apple", abi: "darwin"}

      target_system.os =~ "linux" ->
        arch = with "amd64" <- target_system.arch, do: "x86_64"

        %{target_system | arch: arch}

      true ->
        target_system
    end
  end

  def normalize_target_system(target_system, :zig) do
    cond do
      target_system.abi =~ "darwin" ->
        arch = with "arm" <- target_system.arch, do: "aarch64"

        %{target_system | arch: arch, os: "macos", abi: nil}

      target_system.os =~ "linux" ->
        arch = with "amd64" <- target_system.arch, do: "x86_64"

        %{target_system | arch: arch}

      target_system.os =~ "windows" ->
        arch =
          case target_system.arch do
            "amd64" -> "x64"
            "x86_64" -> "x64"
            _ -> target_system.arch
          end

        %{target_system | arch: arch}

      true ->
        target_system
    end
  end

  @doc """
  Convert system architecture map to its string form.

  ## Example

    iex> system_architecture = FennecPrecompile.SystemInfo.system_architecture()
    %{abi: "darwin21.4.0", arch: "aarch64", os: "apple"}
    iex> FennecPrecompile.SystemInfo.system_architecture_to_string(system_architecture)
    "aarch64-apple-darwin21.4.0"

  """
  def system_architecture_to_string(system_architecture) do
    values =
      for key <- [:arch, :vendor, :os, :abi],
          value = system_architecture[key],
          do: value

    Enum.join(values, "-")
  end

  @doc """
  Get nif version for current node.

  ## Example

    iex> FennecPrecompile.SystemInfo.current_nif_version()
    "2.16"

  """
  @spec current_nif_version() :: String.t()
  def current_nif_version do
    :erlang.system_info(:nif_version) |> List.to_string()
  end

  @doc """
  In case one is using this lib in a newer OTP version, we try to
  find the latest compatible NIF version.
  """
  @spec find_compatible_nif_version(String.t(), [String.t()]) :: {:ok, String.t()} | :error
  def find_compatible_nif_version(vsn, available \\ @available_nif_versions) do
    if vsn in available do
      {:ok, vsn}
    else
      [major, minor | _] = parse_version(vsn)

      available
      |> Enum.map(&parse_version/1)
      |> Enum.filter(fn
        [^major, available_minor | _] when available_minor <= minor -> true
        [_ | _] -> false
      end)
      |> case do
        [] -> :error
        match -> {:ok, match |> Enum.max() |> Enum.join(".")}
      end
    end
  end

  defp parse_version(vsn) do
    vsn |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

  @doc """
  Parse `:erlang.system_info(:system_architecture)` into a map

  The result map may include `:arch`, `:vendor`, `:os` and `:abi` keys
  if `:erlang.system_info/1` returns "ARCH-VENDOR-OS-ABI".

  Or the result will include `:arch`, `:os` and `:abi` keys
  if `:erlang.system_info/1` returns "ARCH-OS-ABI".

  For other cases, an empty map is returned.

  ## Examples

      iex> FennecPrecompile.SystemInfo.system_architecture()
      %{abi: "darwin21.4.0", arch: "aarch64", os: "apple"}

  """
  @spec system_architecture() :: %{atom => String.t()} | %{}
  def system_architecture do
    base =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-")

    triple_keys =
      case length(base) do
        4 ->
          [:arch, :vendor, :os, :abi]

        3 ->
          [:arch, :os, :abi]

        _ ->
          # It's too complicated to find out, and we won't support this for now.
          []
      end

    triple_keys
    |> Enum.zip(base)
    |> Enum.into(%{})
  end

  @doc """
  Override system architeture map with environment variables to support systems like Nerves.

  See: https://hexdocs.pm/nerves/compiling-non-beam-code.html#target-cpu-arch-os-and-abi
  """
  def maybe_override_with_env_vars(original_sys_arch, get_env \\ &System.get_env/1) do
    envs_with_keys = [
      arch: "TARGET_ARCH",
      vendor: "TARGET_VENDOR",
      os: "TARGET_OS",
      abi: "TARGET_ABI"
    ]

    Enum.reduce(envs_with_keys, original_sys_arch, fn {key, env_key}, acc ->
      if env_value = get_env.(env_key) do
        Map.put(acc, key, env_value)
      else
        acc
      end
    end)
  end

  @doc """
  Return a list of default targets.
  """
  def default_targets(convention)

  def default_targets(:rust) do
    ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      arm-unknown-linux-gnueabihf
      aarch64-unknown-linux-gnu
      x86_64-pc-windows-msvc
      x86_64-pc-windows-gnu
    )
  end

  def default_targets(:zig) do
    common_targest = ~w(
        x86_64-linux-gnu
        x86_64-linux-musl
        x86_64-windows-gnu
        aarch64-linux-gnu
        aarch64-linux-musl
        riscv64-linux-musl
      )

    with {:unix, :darwin} <- :os.type() do
      ~w(
        x86_64-macos
        aarch64-macos
      )
    else
      _ -> []
    end ++
      common_targest
  end

  @doc """
  Returns user cache directory.
  """
  def cache_dir(sub_dir \\ "") do
    cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
    cache_dir = :filename.basedir(:user_cache, sub_dir, cache_opts)
    File.mkdir_p!(cache_dir)
    cache_dir
  end
end
