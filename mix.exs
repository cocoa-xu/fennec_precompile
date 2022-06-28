defmodule FennecPrecompile.MixProject do
  use Mix.Project

  def project do
    [
      app: :fennec_precompile,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :public_key]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.6"},
      {:castore, "~> 0.1"}
    ]
  end
end
