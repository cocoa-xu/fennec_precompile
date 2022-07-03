defmodule Fennec.Precompiler do
  @typedoc """
  Target triplets
  """
  @type target :: String.t()

  @doc """
  This callback should return the target triplet for current node.
  """
  @callback current_target() :: {:ok, target} | {:error, String.t()}

  @doc """
  This callback should return a list of triplets for all supported targets.
  """
  @callback all_supported_targets() :: [target]

  @typedoc """
  A map that contains detailed info of a precompiled artefact.

  - `:path`, path to the archived build artefact.
  - `:checksum_algo`, name of the checksum algorithm.
  - `:checksum`, the checksum of the archived build artefact using `:checksum_algo`.
  """
  @type precompiled_artefact_detail :: %{:path => String.t(), :checksum => String.t(), :checksum_algo => Atom.t()}

  @typedoc """
  A tuple that indicates the target and the corresponding precompiled artefact detail info.

  `{target, precompiled_artefact_detail}`.
  """
  @type precompiled_artefact :: {target, precompiled_artefact_detail}

  @typedoc """
  Command line arguments.
  """
  @type cmd_args :: [String.t()]

  @doc """
  This callback should precompile the library to the given target(s).

  Returns a list of `{target, acrhived_artefacts}` if successfully compiled.
  """
  @callback precompile(cmd_args, [target]) :: {:ok, [precompiled_artefact]} | no_return

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
