defmodule Mix.Tasks.Compile.FennecPrecompile do
  use Mix.Task

  @return if Version.match?(System.version(), "~> 1.9"), do: {:ok, []}, else: :ok

  def run(args) do
    Mix.Tasks.Fennec.Precompile.build_native(args)
    @return
  end
end
