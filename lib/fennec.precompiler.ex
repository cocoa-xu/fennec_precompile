defmodule Fennec.Precompiler do
  @doc """
  This callback should return the target triplet for current node.
  """
  @callback current_target() :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  This callback should return a list of triplets for all supported targets.
  """
  @callback all_supported_targets() :: [String.t()]

  @doc """
  This callback should precompile the library to the given target(s).

  Returns a list of `{target, acrhived_artefacts}` if successfully compiled.
  """
  @callback precompile([String.t()], [String.t()]) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Fennec.Precompiler
      use Mix.Task

      @return if Version.match?(System.version(), "~> 1.9"), do: {:ok, []}, else: :ok
      def run(args) do
        with {:ok, precompiled_artefacts} <- precompile(args, all_supported_targets()) do
          IO.puts("#{inspect(precompiled_artefacts)}")
        end
        @return
      end
    end
  end
end
