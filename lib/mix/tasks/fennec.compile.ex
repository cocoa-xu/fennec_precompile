defmodule Mix.Tasks.Compile.FennecPrecompile do
  @moduledoc """
  Drop-in replacement of `:elixir_make`
  """

  use Mix.Task

  @user_config Application.compile_env(:fennec_precompile, :config, [])
  @return if Version.match?(System.version(), "~> 1.9"), do: {:ok, []}, else: :ok

  def run(args) do
    app = Mix.Project.config()[:app]
    config =
      Mix.Project.config()
      |> Keyword.merge(Keyword.get(@user_config, app, []), fn _key, _mix, user_config -> user_config end)
      |> FennecPrecompile.Config.new()

    if config.force_build == true do
      Mix.Tasks.Fennec.Precompile.build_native(args)
    else
      Mix.Tasks.Fennec.Precompile.write_metadata_to_file(config)
      priv_dir = Mix.Tasks.Fennec.Precompile.app_priv(app)

      load_path =
        case :os.type() do
          {:win32, _} -> Path.join([priv_dir, "#{config.nif_filename}.dll"])
          _ -> Path.join([priv_dir, "#{config.nif_filename}.so"])
        end

      with {:skip_if_exists, false} <- {:skip_if_exists, File.exists?(load_path)},
          {:error, precomp_error} <- Mix.Tasks.Fennec.Precompile.download_or_reuse_nif_file(config) do
        message = """
        Error while downloading precompiled NIF: #{precomp_error}.
        You can force the project to build from scratch with:
            mix FennecPrecompile.precompile
        """

        {:error, message}
      else
        _ -> @return
      end
    end
  end
end
