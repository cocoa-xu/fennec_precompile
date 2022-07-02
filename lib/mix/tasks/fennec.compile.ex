defmodule Mix.Tasks.Compile.FennecPrecompile do
  @moduledoc """
  Drop-in replacement of `:elixir_make`
  """

  use Mix.Task

  @user_config Application.compile_env(:fennec_precompile, :config, [])
  @return if Version.match?(System.version(), "~> 1.9"), do: {:ok, []}, else: :ok

  def run(args) do
    app = get_app_name()
    config =
      Mix.Project.config()
      |> Keyword.merge(Keyword.get(@user_config, app, []), fn _key, _mix, user_config -> user_config end)
      |> FennecPrecompile.Config.new()

    if config.force_build == true do
      Mix.Tasks.Fennec.Precompile.build_native(args)
    else
      Mix.Tasks.Fennec.Precompile.write_metadata_to_file(config)
      priv_dir = Path.join([Mix.Project.app_path(), "priv"])
      load_path = "#{priv_dir}/#{config.nif_filename}.so"
      with {:skip_if_exists, false} <- {:skip_if_exists, File.exists?(load_path)},
          {:error, precomp_error} <- Mix.Tasks.Fennec.Precompile.download_or_reuse_nif_file(config) do
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

    @return
  end

  defp get_app_name() do
    Mix.Project.config()[:app]
  end
end
