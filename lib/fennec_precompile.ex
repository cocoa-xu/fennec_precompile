defmodule FennecPrecompile do
  @moduledoc """
  Drop-in library for `:elixir_make` for precompiling and using precompiled NIF
  binaries.

  ## Example

      defmodule MyNative do
        use FennecPrecompile,
          otp_app: Mix.Project.config()[:app],
          version: "0.1.0",
          base_url: "https://github.com/me/my_project/releases/download/v0.1.0",
          nif_filename: "native_nif",
          force_build: false
      end

  ## Options
    - `:otp_app`. Required.

      Specifies the name of the app.

    - `:version`. Optional.

      Defaults to `Mix.Project.config()[:version]`.

      Specifies the version of the app.

    - `:base_url`. Required.

      Specifies the base download URL of the precompiled binaries.

    - `:nif_filename`. Required.

      Specifies the name of the precompiled binary file, excluding the file extension.

    - `:force_build`. Required.

      Indicates whether to force the app to be built.

      The value of this option will always be `true` for pre-releases (like "2.1.0-dev").

      When this value is `false` and there are no local or remote precompiled binaries,
      a compilation error will be raised.

    - `:force_build_args`. Optional.

      Defaults to `[]`.

      This option will be used when `:force_build` is `true`. The optional compiliation
      args will be forwarded to `:elixir_make`.

    - `:force_build_using_zig`. Optional.

      Defaults to `false`.

      This option will be used when `:force_build` is `true`. Set this option to `true`
      to always using `zig` as the C/C++ compiler.

    - `:targets`. Optional.

      A list of targets [supported by Zig](https://ziglang.org/learn/overview/#support-table)
      for which precompiled assets are avilable. By default the following targets are
      configured:

      ### on macOS
        - `x86_64-macos`
        - `x86_64-linux-gnu`
        - `x86_64-linux-musl`
        - `x86_64-windows-gnu`
        - `aarch64-macos`
        - `aarch64-linux-gnu`
        - `aarch64-linux-musl`
        - `riscv64-linux-musl`

      ### on Linux
        - `x86_64-linux-gnu`
        - `x86_64-linux-musl`
        - `x86_64-windows-gnu`
        - `aarch64-linux-gnu`
        - `aarch64-linux-musl`
        - `riscv64-linux-musl`

      `:targets` in the `use`-clause will only be used in the following cases:

        1. `:force_build` is set to `true`. In this case, the `:targets` acts
          as a list of compatible targets in terms of the source code. For example,
          NIFs that are specifically written for ARM64 Linux will fail to compile
          for other OS or CPU architeture. If the source code is not compatible with
          the current node, the build will fail.
        2. `:force_build` is set to `false`. In this case, the `:targets` acts as
          a list of available targets of the precompiled binaries. If there is no
          match with the current node, no precompiled NIF will be downloaded and
          the app will fail to start.
  """

  defmacro __using__(opts) do
    force =
      if Code.ensure_loaded?(Mix.Tasks.Compile.ElixirMake) do
        quote do
          fn use_zig, args ->
            if use_zig do
              Mix.Tasks.Fennec.Precompile.build_native_using_zig(args)
            else
              Mix.Tasks.Compile.ElixirMake.run(args)
            end
          end
        end
      else
        quote do
          raise ":elixir_make dependency is needed to force the build. " <>
                "Add it to your `mix.exs` file: `{:elixir_make, \">= 0.6\", optional: true}`"
        end
      end

    quote do
      require Logger

      opts = unquote(opts)
      otp_app = Keyword.fetch!(opts, :otp_app)
      user_config = Application.compile_env(:fennec_precompile, [:config, otp_app], [])
      # always override using values from user (config/config.exs)
      opts = Keyword.merge(opts, user_config, fn _, _dev, user -> user end)

      case FennecPrecompile.__using__(__MODULE__, opts) do
        {:force_build, config} ->
          force_build_fn = unquote(force)
          with {:ok, []} <- force_build_fn.(config.force_build_using_zig, config.force_build_args) do

            @on_load :load_fennec_precompile
            @fennec_precompiled_load_data config.load_data
            @fennec_precompiled_nif_filename config.nif_filename
            @fennec_precompiled_otp_app config.otp_app

            @doc false
            def load_fennec_precompile do
              # Remove any old modules that may be loaded so we don't get
              # {:error, {:upgrade, 'Upgrade not supported by this NIF library.'}}
              :code.purge(__MODULE__)
              load_path = '#{:code.priv_dir(@fennec_precompiled_otp_app)}/#{@fennec_precompiled_nif_filename}'
              :erlang.load_nif(load_path, @fennec_precompiled_load_data)
            end
          else
            {:error, error} ->
              raise RuntimeError, "#{inspect(error)}"
          end

        {:ok, config} ->
          @on_load :load_fennec_precompile
          @fennec_precompiled_load_data config.load_data
          @fennec_precompiled_nif_filename config.nif_filename
          @fennec_precompiled_otp_app config.otp_app

          @doc false
          def load_fennec_precompile do
            # Remove any old modules that may be loaded so we don't get
            # {:error, {:upgrade, 'Upgrade not supported by this NIF library.'}}
            :code.purge(__MODULE__)
            load_path = '#{:code.priv_dir(@fennec_precompiled_otp_app)}/#{@fennec_precompiled_nif_filename}'
            :erlang.load_nif(load_path, @fennec_precompiled_load_data)
          end

        {:error, precomp_error} ->
          raise precomp_error
      end
    end
  end

  # A helper function to extract the logic from __using__ macro.
  @doc false
  def __using__(module, opts) do
    config =
      opts
      |> Keyword.put_new(:module, module)
      |> FennecPrecompile.Config.new()

    if config.force_build == true do
      {:force_build, config}
    else
      otp_app = config.otp_app
      write_metadata_to_file(config)
      load_path = "#{:code.priv_dir(otp_app)}/#{config.nif_filename}.so"
      with {:skip_if_exists, false} <- {:skip_if_exists, File.exists?(load_path)},
          {:error, precomp_error} <- FennecPrecompile.download_or_reuse_nif_file(config) do
        message = """
        Error while downloading precompiled NIF: #{precomp_error}.
        You can force the project to build from scratch with:
            mix fennec.precompile
        """

        {:error, message}
      else
        _ -> {:ok, config}
      end
    end
  end

  alias FennecPrecompile.Config
  require Logger

  @available_nif_versions ~w(2.16)
  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]

  def write_metadata_to_file(%Config{} = config) do
    app = config.otp_app

    with {:ok, target} <- target(config.targets) do
      metadata = %{
        otp_app: app,
        cached_tar_gz: Path.join([cache_dir(""), "#{target}.tar.gz"]),
        base_url: config.base_url,
        target: target,
        targets: config.targets,
        version: config.version
      }

      write_metadata(app, metadata)
    end
    :ok
  end

  def download_or_reuse_nif_file(%Config{} = config) do
    Logger.debug("Download/Reuse: #{inspect(config)}")
    cache_dir = cache_dir("")

    with {:ok, target} <- target(config.targets) do
      app = config.otp_app
      version = config.version
      tar_filename = "#{app}-nif-#{config.nif_version}-#{target}-#{version}.tar.gz"
      cached_tar_gz = Path.join([cache_dir, tar_filename])

      result = %{
        load?: true,
        load_data: config.load_data
      }

      if !File.exists?(cached_tar_gz) do
        with :ok <- File.mkdir_p(cache_dir),
             {:ok, tar_gz} <- download_tar_gz(config.base_url, tar_filename),
             :ok <- File.write(cached_tar_gz, tar_gz) do
            Logger.debug("NIF cached at #{cached_tar_gz} and extracted to #{app_priv(app)}")
        end
      end

      with {:file_exists, true} <- {:file_exists, File.exists?(cached_tar_gz)},
           {:file_integrity, :ok} <- {:file_integrity, check_file_integrity(cached_tar_gz, app)},
           {:restore_nif, true} <- {:restore_nif, restore_nif_file(cached_tar_gz, app)} do
            {:ok, result}
      else
        {:file_exists, _} ->
          {:error, "Cache file not exists or cannot download"}
        {:file_integrity, _} ->
          {:error, "Cache file integrity check failed"}
        {:restore_nif, status} ->
          {:error, "Cannot restore nif from cache: #{inspect(status)}"}
      end
    end
  end

  def restore_nif_file(cached_tar_gz, app) do
    Logger.debug("Restore NIF for current node from: #{cached_tar_gz}")
    {:ok, files} = :erl_tar.extract(cached_tar_gz, [:compressed, :memory])
    root = app_priv(app)
    Enum.map(files, fn {filepath, data} ->
      filepath = Path.join([root, filepath])
      file_dir = Path.basename(filepath)
      if !File.dir?(file_dir) do
        File.mkdir_p!(file_dir)
      end
      :ok = File.write!(filepath, data)
    end)
    |> Enum.all?()
  end

  @doc """
  Returns URLs for NIFs based on its module name.
  The module name is the one that defined the NIF and this information
  is stored in a metadata file.
  """
  def available_nif_urls(app) when is_atom(app) do
    metadata =
      app
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{targets: targets, base_url: base_url, version: version} ->
        for target_triple <- targets, nif_version <- @available_nif_versions do
          target = "#{to_string(app)}-nif-#{nif_version}-#{target_triple}-#{version}"

          tar_gz_file_url(base_url, target)
        end

      _ ->
        raise "metadata about current target for the app #{inspect(app)} is not available. " <>
                "Please compile the project again with: `mix fennec.precompile`"
    end
  end

  @doc """
  Returns the file URL to be downloaded for current target.
  It receives the NIF module.
  """
  def current_target_nif_url(app) do
    metadata =
      app
      |> metadata_file()
      |> read_map_from_file()

    nif_version = "#{:erlang.system_info(:nif_version)}"
    case metadata do
      %{base_url: base_url, target: target, version: version} ->
        target = "#{to_string(app)}-nif-#{nif_version}-#{target}-#{version}"
        tar_gz_file_url(base_url, target)

      _ ->
        raise "metadata about current target for the app #{inspect(app)} is not available. " <>
                "Please compile the project again with: `mix fennec.precompile`"
    end
  end

  defp tar_gz_file_url(base_url, file_name) do
    uri = URI.parse(base_url)

    uri =
      Map.update!(uri, :path, fn path ->
        Path.join(path || "", "#{file_name}.tar.gz")
      end)

    to_string(uri)
  end

  defp app_priv(%Config{} = config) do
    :code.priv_dir(config.otp_app)
  end

  defp app_priv(app) when is_atom(app) do
    :code.priv_dir(app)
  end

  def cache_dir(sub_dir) do
    cache_dir = System.get_env("FENNEC_CACHE_DIR")
    cache_dir =
      if cache_dir do
        Path.join(cache_dir, sub_dir)
      else
        cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
        :filename.basedir(:user_cache, Path.join("fennec_precompiled", sub_dir), cache_opts)
      end
    File.mkdir_p!(cache_dir)
    cache_dir
  end

  @doc """
  Returns the target triple for download or compile and load.
  This function is translating and adding more info to the system
  architecture returned by Elixir/Erlang to one used by Zig.
  The returned string has the following format:
      "ARCHITECTURE-OS-ABI"
  ## Examples
      iex> FennecPrecompile.target()
      {:ok, "x86_64-linux-gnu"}
      iex> FennecPrecompile.target()
      {:ok, "aarch64-macos"}
  """
  def target(config \\ target_config(), available_targets) do
    arch_os =
      case config.os_type do
        {:unix, t} ->
          arch_os =
            config.target_system
            |> normalize_arch_os()
            |> system_arch_to_string()
            cond do
              t == :darwin ->
                case arch_os do
                  "aarch64-apple-macos" -> "aarch64-macos"
                  "x86_64-apple-macos" -> "x86_64-macos"
                  _ -> arch_os
                end
              true -> arch_os
            end

        {:win32, _} ->
          existing_target =
            config.target_system
            |> system_arch_to_string()

          # For when someone is setting "TARGET_*" vars on Windows
          if existing_target in available_targets do
            existing_target
          else
            # 32 or 64 bits
            arch =
              case config.word_size do
                4 -> "i686"
                8 -> "x86_64"
                _ -> "unknown"
              end

            config.target_system
            |> Map.put_new(:arch, arch)
            |> Map.put_new(:os, "windows")
            |> Map.put_new(:abi, "msvc")
            |> system_arch_to_string()
          end
      end

    cond do
      arch_os not in available_targets ->
        {:error,
         "precompiled NIF is not available for this target: #{inspect(arch_os)}.\n" <>
           "The available targets are:\n - #{Enum.join(available_targets, "\n - ")}"}

      config.nif_version not in @available_nif_versions ->
        {:error,
         "precompiled NIF is not available for this NIF version: #{inspect(config.nif_version)}.\n" <>
           "The available NIF versions are:\n - #{Enum.join(@available_nif_versions, "\n - ")}"}

      true ->
        {:ok, arch_os}
    end
  end

  defp normalize_arch_os(target_system) do
    cond do
      target_system.os =~ "darwin" ->
        arch = with "arm" <- target_system.arch, do: "aarch64"

        %{target_system | arch: arch, os: "macos"}

      target_system.os =~ "linux" ->
        arch = with "amd64" <- target_system.arch, do: "x86_64"

        %{target_system | arch: arch}

      true ->
        target_system
    end
  end

  defp system_arch_to_string(system_arch) do
    values =
      for key <- [:arch, :os, :abi],
          value = system_arch[key],
          do: value

    Enum.join(values, "-")
  end

  def current_nif_version, do: :erlang.system_info(:nif_version) |> List.to_string()
  defp target_config do
    current_nif_version = current_nif_version()

    nif_version =
      case find_compatible_nif_version(current_nif_version, @available_nif_versions) do
        {:ok, vsn} ->
          vsn

        :error ->
          # In case of error, use the current so we can tell the user.
          current_nif_version
      end

    current_system_arch = system_arch()

    %{
      os_type: :os.type(),
      target_system: maybe_override_with_env_vars(current_system_arch),
      word_size: :erlang.system_info(:wordsize),
      nif_version: nif_version
    }
  end

  # In case one is using this lib in a newer OTP version, we try to
  # find the latest compatible NIF version.
  @doc false
  def find_compatible_nif_version(vsn, available) do
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

  # Returns a map with `:arch`, `:os` and maybe `:abi`.
  defp system_arch do
    base =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-")

    triple_keys =
      case length(base) do
        4 ->
          [:arch, :vendor, :os, :abi]

        3 ->
          [:arch, :vendor, :os]

        _ ->
          # It's too complicated to find out, and we won't support this for now.
          []
      end

    triple_keys
    |> Enum.zip(base)
    |> Enum.into(%{})
  end

  # The idea is to support systems like Nerves.
  # See: https://hexdocs.pm/nerves/compiling-non-beam-code.html#target-cpu-arch-os-and-abi
  @doc false
  def maybe_override_with_env_vars(original_sys_arch, get_env \\ &System.get_env/1) do
    envs_with_keys = [
      arch: "TARGET_ARCH",
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

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  defp write_metadata(app, metadata) do
    metadata_file = metadata_file(app)
    existing = read_map_from_file(metadata_file)

    unless Map.equal?(metadata, existing) do
      dir = Path.dirname(metadata_file)
      :ok = File.mkdir_p(dir)

      File.write!(metadata_file, inspect(metadata, limit: :infinity, pretty: true))
    end

    :ok
  end

  defp metadata_file(app) do
    fennec_precompiled_cache = cache_dir("metadata")
    Path.join(fennec_precompiled_cache, "metadata-#{app}.exs")
  end

  defp download_tar_gz(base_url, target_name) do
    "#{base_url}/#{target_name}"
    |> download_nif_artifact()
  end

  defp download_nif_artifact(url) do
    url = String.to_charlist(url)
    Logger.debug("Downloading NIF from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    if proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
      Logger.debug("Using HTTP_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)

      :httpc.set_options([{:proxy, {{String.to_charlist(host), port}, []}}])
    end

    if proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      Logger.debug("Using HTTPS_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)
      :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])
    end

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    cacertfile = CAStore.file_path() |> String.to_charlist()

    http_options = [
      ssl: [
        verify: :verify_peer,
        cacertfile: cacertfile,
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch NIF from #{url}: #{inspect(other)}"}
    end
  end

  # Download a list of files from URLs and calculate its checksum.
  # Returns a list with details of the download and the checksum of each file.
  @doc false
  def download_nif_artifacts_with_checksums!(urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)

    tasks =
      Task.async_stream(urls, fn url -> {url, download_nif_artifact(url)} end, timeout: :infinity)

    cache_dir = cache_dir("")
    :ok = File.mkdir_p(cache_dir)

    Enum.flat_map(tasks, fn {:ok, result} ->
      with {:download, {url, download_result}} <- {:download, result},
           {:download_result, {:ok, body}} <- {:download_result, download_result},
           hash <- :crypto.hash(@checksum_algo, body),
           path <- Path.join(cache_dir, basename_from_url(url)),
           {:file, :ok} <- {:file, File.write(path, body)} do
        checksum = Base.encode16(hash, case: :lower)

        Logger.debug(
          "NIF cached at #{path} with checksum #{inspect(checksum)} (#{@checksum_algo})"
        )

        [
          %{
            url: url,
            path: path,
            checksum: checksum,
            checksum_algo: @checksum_algo
          }
        ]
      else
        {:file, error} ->
          raise "could not write downloaded file to disk. Reason: #{inspect(error)}"

        {context, result} ->
          if ignore_unavailable? do
            Logger.debug(
              "Skip an unavailable NIF artifact. " <>
                "Context: #{inspect(context)}. Reason: #{inspect(result)}"
            )

            []
          else
            raise "could not finish the download of NIF artifacts. " <>
                    "Context: #{inspect(context)}. Reason: #{inspect(result)}"
          end
      end
    end)
  end

  defp basename_from_url(url) do
    uri = URI.parse(url)

    uri.path
    |> String.split("/")
    |> List.last()
  end

  defp checksum_map(otp_app) when is_atom(otp_app) do
    checksum_file(otp_app)
    |> read_map_from_file()
  end

  defp check_file_integrity(file_path, otp_app) when is_atom(otp_app) do
    checksum_map(otp_app)
    |> check_integrity_from_map(file_path)
  end

  # It receives the map of %{ "filename" => "algo:checksum" } with the file path
  @doc false
  def check_integrity_from_map(checksum_map, file_path) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, file_path),
         :ok <- validate_checksum_algo(algo) do
      compare_checksum(file_path, algo, hash)
    end
  end

  defp find_checksum(checksum_map, file_path) do
    basename = Path.basename(file_path)

    case Map.fetch(checksum_map, basename) do
      {:ok, algo_with_hash} ->
        [algo, hash] = String.split(algo_with_hash, ":")
        algo = String.to_existing_atom(algo)

        {:ok, {algo, hash}}

      :error ->
        {:error,
         "the precompiled NIF file does not exist in the checksum file. " <>
           "Please consider run: `mix fennec_precompiled.download #{Mix.Project.config()[:app]} --only-local` to generate the checksum file."}
    end
  end

  defp validate_checksum_algo(algo) do
    if algo in @checksum_algorithms do
      :ok
    else
      {:error,
       "checksum algorithm is not supported: #{inspect(algo)}. " <>
         "The supported ones are:\n - #{Enum.join(@checksum_algorithms, "\n - ")}"}
    end
  end

  def compute_checksum(file_path, algo) do
    case File.read(file_path) do
      {:ok, content} ->
        file_hash =
          algo
          |> :crypto.hash(content)
          |> Base.encode16(case: :lower)
          {:ok, "#{algo}", "#{file_hash}"}
      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)}. " <>
           "Reason: #{inspect(reason)}"}
    end
  end

  defp compare_checksum(file_path, algo, expected_checksum) do
    case compute_checksum(file_path, algo) do
      {:ok, _, file_hash} ->
        if file_hash == expected_checksum do
          :ok
        else
          {:error, "the integrity check failed because the checksum of files does not match"}
        end

      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)}. " <>
           "Reason: #{inspect(reason)}"}
    end
  end

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(app, checksums) do
    file = checksum_file(app)

    pairs =
      for %{path: path, checksum: checksum, checksum_algo: algo} <- checksums, into: %{} do
        basename = Path.basename(path)
        checksum = "#{algo}:#{checksum}"
        {basename, checksum}
      end

    lines =
      for {filename, checksum} <- Enum.sort(pairs) do
        ~s(  "#{filename}" => #{inspect(checksum, limit: :infinity)},\n)
      end

    File.write!(file, ["%{\n", lines, "}\n"])
  end

  def checksum_file(otp_app) when is_atom(otp_app) do
    # Saves the file in the project root.
    Path.join(File.cwd!(), "checksum-#{to_string(otp_app)}.exs")
  end
end
