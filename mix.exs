defmodule FennecPrecompile.MixProject do
  use Mix.Project

  @app :fennec_precompile
  @version "0.1.3"
  @github_url "https://github.com/cocoa-xu/fennec_precompile"
  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Drop-in library for `:elixir_make` for precompiling NIF binaries with Zig as the cross-compiler.",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :public_key]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.6", runtime: false},
      {:castore, "~> 0.1", runtime: false},
      {:ex_doc, "~> 0.23", only: :docs, runtime: false}
    ]
  end

  defp package() do
    [
      name: to_string(@app),
      files: ~w(lib mix.exs README* LICENSE*),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url}
    ]
  end

  defp docs do
    [
      main: "Mix.Tasks.Fennec.Precompile",
      extras: ["PRECOMPILATION_GUIDE.md"],
      source_ref: "v#{@version}",
      source_url: @github_url
    ]
  end
end
