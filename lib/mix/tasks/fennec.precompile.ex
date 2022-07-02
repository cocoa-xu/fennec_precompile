defmodule Mix.Tasks.Fennec.Precompile do
  @moduledoc """
  Download and use precompiled NIFs safely with checksums.

  Fennec Precompile is a tool for library maintainers that use `:elixir_make`
  and wish to ship precompiled binaries. This tool aims to be a drop-in
  replacement for `:elixir_make`.

  It helps by removing the need to have the C/C++ compiler and other dependencies
  installed in the user's machine.

  Check the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for details.

  """

  use Mix.Task
  require Logger

  @user_config Application.compile_env(:fennec_precompile, :config, [])
  @return if Version.match?(System.version(), "~> 1.9"), do: {:ok, []}, else: :ok

  @impl true
  def run(args) do
    build_with_targets(args, compile_targets(), true)
  end

  def build_with_targets(args, targets, post_clean) do
    saved_cwd = File.cwd!()
    cache_dir = System.get_env("FENNEC_CACHE_DIR", nil)
    if cache_dir do
      System.put_env("FENNEC_CACHE_DIR", cache_dir)
    end
    cache_dir = FennecPrecompile.cache_dir("")

    app = get_app_name()
    do_fennec_precompile(app, args, targets, saved_cwd, cache_dir)
    if post_clean do
      make_priv_dir(app, :clean)
    else
      with {:ok, target} <- FennecPrecompile.target(targets) do
        version = get_app_version()
        nif_version = "#{:erlang.system_info(:nif_version)}"
        tar_filename = "#{app}-nif-#{nif_version}-#{target}-#{version}.tar.gz"
        cached_tar_gz = Path.join([cache_dir, tar_filename])
        FennecPrecompile.restore_nif_file(cached_tar_gz, app)
      end
    end
    Mix.Project.build_structure()
    @return
  end

  def build_native_using_zig(args) do
    with {:ok, target} <- get_native_target() do
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

  defp get_native_target() do
    with {:ok, targets} <- FennecPrecompile.target(FennecPrecompile.Config.default_targets()) do
      {:ok, targets}
    else
      _ ->
        custom_native_target = System.get_env("FENNEC_PRECOMPILE_NATIVE_TARGET")
        if custom_native_target == nil do
          raise RuntimeError, "Cannot identify triplets for native target"
        else
          {:ok, custom_native_target}
        end
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

  defp compile_targets() do
    targets = System.get_env("FENNEC_PRECOMPILE_TARGETS")
    if targets do
      String.split(targets, ",", trim: true)
    else
      app = get_app_name()
      user_targets = Keyword.get(Keyword.get(@user_config, app, []), :targets)
      if user_targets != nil do
        user_targets
      else
        FennecPrecompile.Config.default_targets()
      end
    end
  end

  defp do_fennec_precompile(app, args, targets, saved_cwd, cache_dir) do
    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    checksums = fennec_precompile(app, args, targets, cache_dir)
    FennecPrecompile.write_checksum!(app, checksums)

    File.cd!(saved_cwd)
    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)
  end

  defp fennec_precompile(app, args, targets, cache_dir) do
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

      {archive_full_path, archive_tar_gz} = create_precompiled_archive(target, cache_dir)
      {:ok, algo, checksum} = FennecPrecompile.compute_checksum(archive_full_path, :sha256)
      [%{path: archive_tar_gz, checksum_algo: algo, checksum: checksum} | checksums]
    end)
  end

  defp create_precompiled_archive(target, cache_dir) do
    saved_cwd = File.cwd!()
    app = get_app_name()
    version = get_app_version()

    app_priv = app_priv(app)
    File.cd!(app_priv)
    nif_version = FennecPrecompile.current_nif_version()

    archive_filename = "#{app}-nif-#{nif_version}-#{target}-#{version}"
    archive_tar_gz = "#{archive_filename}.tar.gz"
    archive_full_path = Path.expand(Path.join([cache_dir, archive_tar_gz]))
    Logger.debug("Creating precompiled archive: #{archive_full_path}")

    System.cmd("tar", ["-czf", "--hole-detection=raw", archive_full_path, "."])

    File.cd!(saved_cwd)
    {archive_full_path, archive_tar_gz}
  end

  defp get_app_name() do
    System.get_env("FENNEC_PRECOMPILE_OTP_APP", to_string(Mix.Project.config()[:app]))
    |> String.to_atom()
  end

  defp get_app_version() do
    System.get_env("FENNEC_PRECOMPILE_VERSION", to_string(Mix.Project.config()[:version]))
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
end
