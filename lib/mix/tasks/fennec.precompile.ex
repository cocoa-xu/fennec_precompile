defmodule Mix.Tasks.Fennec.Precompile do
  @moduledoc """
  Download and use precompiled NIFs safely with checksums.

  Fennec Precompile is a tool for library maintainers that use `:elixir_make`
  and wish to ship precompiled binaries. This tool aims to be a drop-in
  replacement for `:elixir_make`.

  It helps by removing the need to have the C/C++ compiler and other dependencies
  installed in the user's machine.

  Check the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for details.

  ## Options to set in the `project` function of the `mix.exs` file.

    - `:fennec_base_url`. Required.

      Specifies the base download URL of the precompiled binaries.

    - `:fennec_nif_filename`. Optional.

      Specifies the name of the precompiled binary file, excluding the file extension.

    - `:fennec_force_build`. Optional.

      Indicates whether to force the app to be built.

      The value of this option will always be `true` for pre-releases (like "2.1.0-dev").

      When this value is `false` and there are no local or remote precompiled binaries,
      a compilation error will be raised.

    - `:fennec_force_build_args`. Optional.

      Defaults to `[]`.

      This option will be used when `:force_build` is `true`. The optional compiliation
      args will be forwarded to `:elixir_make`.

    - `:fennec_force_build_using_zig`. Optional.

      Defaults to `false`.

      This option will be used when `:force_build` is `true`. Set this option to `true`
      to always using `zig` as the C/C++ compiler.

    - `:fennec_targets`. Optional.

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

      `:fennec_targets` in the `project` will only be used in the following cases:

        1. When `:fennec_force_build` is set to `true`. In this case, the `:targets` acts
          as a list of compatible targets in terms of the source code. For example,
          NIFs that are specifically written for ARM64 Linux will fail to compile
          for other OS or CPU architeture. If the source code is not compatible with
          the current node, the build will fail.
        2. When `:fennec_force_build` is set to `false`. In this case, the `:targets` acts as
          a list of available targets of the precompiled binaries. If there is no
          match with the current node, no precompiled NIF will be downloaded and
          the app will fail to start.
  """

  require Logger
  alias Fennec.Config

  use Fennec.Precompiler

  @crosscompiler :zig
  @available_nif_versions ~w(2.16)

  @impl true
  def all_supported_targets() do
    Fennec.SystemInfo.default_targets(@crosscompiler)
  end

  @impl true
  def current_target() do
    Fennec.SystemInfo.target(@crosscompiler)
  end

  @impl true
  def precompile(args, targets) do
    IO.puts("#{inspect(targets)}")

    saved_cwd = File.cwd!()
    cache_dir = System.get_env("FENNEC_CACHE_DIR", nil)
    if cache_dir do
      System.put_env("FENNEC_CACHE_DIR", cache_dir)
    end
    cache_dir = Fennec.SystemInfo.cache_dir()

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    precompiled_artefacts = do_fennec_precompile(app, version, args, targets, saved_cwd, cache_dir)
    with {:ok, target} <- Fennec.SystemInfo.target(targets) do
      nif_version = "#{:erlang.system_info(:nif_version)}"
      tar_filename = archive_filename(app, version, nif_version, target)
      cached_tar_gz = Path.join([cache_dir, tar_filename])
      restore_nif_file(cached_tar_gz, app)
    end
    Mix.Project.build_structure()
    {:ok, precompiled_artefacts}
  end

  def build_with_targets(args, targets, post_clean) do
    saved_cwd = File.cwd!()
    cache_dir = System.get_env("FENNEC_CACHE_DIR", nil)
    if cache_dir do
      System.put_env("FENNEC_CACHE_DIR", cache_dir)
    end
    cache_dir = Fennec.SystemInfo.cache_dir()

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    do_fennec_precompile(app, version, args, targets, saved_cwd, cache_dir)
    if post_clean do
      make_priv_dir(app, :clean)
    else
      with {:ok, target} <- Fennec.SystemInfo.target(targets) do
        nif_version = "#{:erlang.system_info(:nif_version)}"
        tar_filename = archive_filename(app, version, nif_version, target)
        cached_tar_gz = Path.join([cache_dir, tar_filename])
        restore_nif_file(cached_tar_gz, app)
      end
    end
    Mix.Project.build_structure()
    @return
  end

  def build_native_using_zig(args) do
    with {:ok, target} <- Fennec.SystemInfo.target(:zig) do
      build_with_targets(args, [target], false)
    end
  end

  def build_native(args) do
    if always_use_zig?() do
      build_native_using_zig(args)
    else
      Mix.Tasks.Compile.ElixirMake.run(args)
    end
  end

  defp always_use_zig?() do
    always_use_zig?(System.get_env("FENNEC_PRECOMPILE_ALWAYS_USE_ZIG", "NO"))
  end

  defp always_use_zig?("true"), do: true
  defp always_use_zig?("TRUE"), do: true
  defp always_use_zig?("YES"), do: true
  defp always_use_zig?("yes"), do: true
  defp always_use_zig?("y"), do: true
  defp always_use_zig?("on"), do: true
  defp always_use_zig?("ON"), do: true
  defp always_use_zig?(_), do: false

  defp do_fennec_precompile(app, version, args, targets, saved_cwd, cache_dir) do
    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    precompiled_artefacts = fennec_precompile(app, version, args, targets, cache_dir)
    write_checksum!(app, precompiled_artefacts)

    File.cd!(saved_cwd)
    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)
    precompiled_artefacts
  end

  defp fennec_precompile(app, version, args, targets, cache_dir) do
    Enum.reduce(targets, [], fn target, checksums ->
      Logger.debug("Current compiling target: #{target}")
      make_priv_dir(app, :clean)
      {cc, cxx} =
        case {:os.type(), target} do
          {{:unix, :darwin}, "x86_64-macos" <> _} ->
            {"gcc -arch x86_64", "g++ -arch x86_64"}
          {{:unix, :darwin}, "aarch64-macos" <> _} ->
            {"gcc -arch arm64", "g++ -arch arm64"}
          _ ->
            {"zig cc -target #{target}", "zig c++ -target #{target}"}
        end
      System.put_env("CC", cc)
      System.put_env("CXX", cxx)
      System.put_env("CPP", cxx)
      Mix.Tasks.Compile.ElixirMake.run(args)

      {archive_full_path, archive_tar_gz} = create_precompiled_archive(app, version, target, cache_dir)
      {:ok, algo, checksum} = compute_checksum(archive_full_path, :sha256)
      [{target, %{path: archive_tar_gz, checksum_algo: algo, checksum: checksum}} | checksums]
    end)
  end

  defp create_precompiled_archive(app, version, target, cache_dir) do
    saved_cwd = File.cwd!()

    app_priv = app_priv(app)
    File.cd!(app_priv)
    nif_version = Fennec.SystemInfo.current_nif_version()

    archive_tar_gz = archive_filename(app, version, nif_version, target)
    archive_full_path = Path.expand(Path.join([cache_dir, archive_tar_gz]))
    File.mkdir_p!(cache_dir)
    Logger.debug("Creating precompiled archive: #{archive_full_path}")

    filelist = build_file_list_at(app_priv)
    File.cd!(app_priv)
    :ok = :erl_tar.create(archive_full_path, filelist, [:compressed])

    File.cd!(saved_cwd)
    {archive_full_path, archive_tar_gz}
  end

  defp build_file_list_at(dir) do
    saved_cwd = File.cwd!()
    File.cd!(dir)
    {filelist, _} = build_file_list_at(".", %{}, [])
    File.cd!(saved_cwd)
    Enum.map(filelist, &to_charlist/1)
  end

  defp build_file_list_at(dir, visited, filelist) do
    visited? = Map.get(visited, dir)
    if visited? do
      {filelist, visited}
    else
      visited = Map.put(visited, dir, true)
      saved_cwd = File.cwd!()

      case {File.dir?(dir), File.read_link(dir)} do
        {true, {:error, _}} ->
          File.cd!(dir)
          cur_filelist = File.ls!()
          {files, folders} =
            Enum.reduce(cur_filelist, {[], []}, fn filepath, {files, folders} ->
              if File.dir?(filepath) do
                symlink_dir? = Path.join([File.cwd!(), filepath])
                case File.read_link(symlink_dir?) do
                  {:error, _} ->
                    {files, [filepath | folders]}
                  {:ok, _} ->
                    {[Path.join([dir, filepath]) | files], folders}
                end
              else
                {[Path.join([dir, filepath]) | files], folders}
              end
            end)
          File.cd!(saved_cwd)

          filelist = files ++ filelist ++ [dir]
          {files_in_folder, visited} =
            Enum.reduce(folders, {[], visited}, fn folder_path, {files_in_folder, visited} ->
              {filelist, visited} = build_file_list_at(Path.join([dir, folder_path]), visited, files_in_folder)
              {files_in_folder ++ filelist, visited}
            end)
          filelist = filelist ++ files_in_folder
          {filelist, visited}
      _ ->
        {filelist, visited}
      end
    end
  end

  defp app_priv(app) when is_atom(app) do
    build_path = Mix.Project.build_path()
    Path.join([build_path, "lib", "#{app}", "priv"])
  end

  defp make_priv_dir(app, :clean) when is_atom(app) do
    app_priv = app_priv(app)
    File.rm_rf!(app_priv)
    make_priv_dir(app)
  end

  defp make_priv_dir(app) when is_atom(app) do
    File.mkdir_p!(app_priv(app))
  end

  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]

  def write_metadata_to_file(%Config{} = config) do
    app = config.app

    with {:ok, target} <- Fennec.SystemInfo.target(:zig) do
      archived_artefact_file = archive_filename(app, config.version, Fennec.SystemInfo.current_nif_version(), target)
      metadata = %{
        app: app,
        cached_tar_gz: Path.join([Fennec.SystemInfo.cache_dir(), archived_artefact_file]),
        base_url: config.base_url,
        target: target,
        targets: config.targets,
        version: config.version
      }

      write_metadata(app, metadata)
    end
    :ok
  end

  def archive_filename(app, version, nif_version, target) do
    "#{app}-nif-#{nif_version}-#{target}-#{version}.tar.gz"
  end

  def download_or_reuse_nif_file(%Config{} = config) do
    Logger.debug("Download/Reuse: #{inspect(config)}")
    cache_dir = Fennec.SystemInfo.cache_dir()

    with {:ok, target} <- Fennec.SystemInfo.target(config.targets) do
      app = config.app
      tar_filename = archive_filename(app, config.version, config.nif_version, target)
      cached_tar_gz = Path.join([cache_dir, tar_filename])

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
            :ok
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
    :erl_tar.extract(cached_tar_gz, [:compressed, {:cwd, to_string(app_priv(app))}])
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
    fennec_precompiled_cache = Fennec.SystemInfo.cache_dir("metadata")
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

    cache_dir = Fennec.SystemInfo.cache_dir()

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

  defp checksum_map(app) when is_atom(app) do
    checksum_file(app)
    |> read_map_from_file()
  end

  defp check_file_integrity(file_path, app) when is_atom(app) do
    checksum_map(app)
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

  defp compute_checksum(file_path, algo) do
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
  def write_checksum!(app, precompiled_artefacts) do
    file = checksum_file(app)

    pairs =
      for {_target, %{path: path, checksum: checksum, checksum_algo: algo}} <- precompiled_artefacts, into: %{} do
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

  defp checksum_file(app) when is_atom(app) do
    # Saves the file in the project root.
    Path.join(File.cwd!(), "checksum-#{to_string(app)}.exs")
  end
end
