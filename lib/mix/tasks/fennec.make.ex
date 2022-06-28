defmodule Mix.Tasks.Compile.FennecPrecompile do
  use Mix.Task
  require Logger

  @moduledoc """
  Download and use precompiled NIFs safely with checksums.
  Fennec Precompile is a tool for library maintainers that use `:elixir_make`
  and wish to ship precompiled binaries. This tool aims to be a drop-in
  replacement for `:elixir_make`.
  It helps by removing the need to have the C/C++ compiler and other dependencies
  installed in the user's machine.
  Check the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for details.
  ## Example
      defmodule MyNative do
        use FennecPrecompile,
          base_url: "https://github.com/me/my_project/releases/download/v0.1.0",
          version: "0.1.0"
      end
  ## Options
    * `:base_url` - A valid URL that is used as base path for the NIF file.
    * `:version` - The version of precompiled assets (it is part of the NIF filename).
    * `:targets` - A list of targets [supported by
      Zig](https://ziglang.org/learn/overview/#support-table) for which
      precompiled assets are avilable. By default the following targets are
      configured:
      #{Enum.map_join(FennecPrecompile.Config.default_targets(), "\n", &"    - `#{&1}`")}
  """
  def run(args) do
    case args do
      ["--fennec_precompile" | other_args] ->
        saved_cwd = File.cwd!()
        cache_dir = System.get_env("FENNEC_CACHE_DIR", nil)
        if cache_dir do
          System.put_env("FENNEC_CACHE_DIR", cache_dir)
        end
        cache_dir = FennecPrecompile.cache_dir("")
        do_fennec_precompile(other_args, saved_cwd, cache_dir)

        make_priv_dir(:clean)
        with {:ok, target} <- FennecPrecompile.target(FennecPrecompile.Config.default_targets()) do
          tar_filename = "#{target}.tar.gz"
          cached_tar_gz = Path.join([cache_dir, tar_filename])
          FennecPrecompile.restore_nif_file(cached_tar_gz)
        end
      _ ->
        Mix.Tasks.Compile.ElixirMake.run(args)
    end

    Mix.Project.build_structure()

    :ok
  end

  defp do_fennec_precompile(other_args, saved_cwd, cache_dir) do
    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    checksum_map = fennec_precompile(other_args, cache_dir)
    File.write!("checksum-#{Mix.Project.config()[:app]}.exs", inspect(checksum_map))

    File.cd!(saved_cwd)
    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)
  end

  defp fennec_precompile(args, cache_dir) do
    Enum.reduce(FennecPrecompile.Config.default_targets(), %{}, fn target, checksum_map ->
      Logger.debug("Current compiling target: #{target}")
      make_priv_dir(:clean)
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

      {archive_full_path, archive_tar_gz} = create_precompiled_archive(target, cache_dir)
      {:ok, algo, checksum} = FennecPrecompile.compute_checksum(archive_full_path, :sha256)
      Map.put(checksum_map, archive_tar_gz, "#{algo}:#{checksum}")
    end)
  end

  defp create_precompiled_archive(target, cache_dir) do
    saved_cwd = File.cwd!()
    app_priv = app_priv()
    File.cd!(app_priv)
    nif_version = FennecPrecompile.current_nif_version()
    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    archive_filename = "#{to_string(app)}-nif-#{nif_version}-#{target}-#{version}"
    archive_tar_gz = "#{archive_filename}.tar.gz"
    archive_full_path = Path.expand(Path.join([cache_dir, archive_tar_gz]))
    Logger.debug("Creating precompiled archive: #{archive_full_path}")

    System.cmd("tar", ["-czf", archive_full_path, "."])

    File.cd!(saved_cwd)
    {archive_full_path, archive_tar_gz}
  end

  defp app_priv() do
    app_priv(Mix.Project.config())
  end

  defp app_priv(config) do
      config
      |> Mix.Project.app_path()
      |> Path.join("priv")
  end

  defp make_priv_dir(:clean) do
    File.rm_rf(app_priv())
    make_priv_dir()
  end

  defp make_priv_dir() do
    File.mkdir_p!(app_priv())
  end
end
