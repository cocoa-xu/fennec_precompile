# FennecPrecompile

Drop-in plugin for `:elixir_make` that precompiles NIF binaries and pull NIF libraries.

## Usage
Change the `:elixir_make` compiler to:

```elixir
def project do
  [
    # ...
    compilers: [:fennec_precompile] ++ Mix.compilers(),
    # ...
  ]
end
```

Then run `mix compile` with the `--fennec_precompile` flag.
```elixir
export FENNEC_CACHE_DIR="$(pwd)/cache"
mkdir -p "${FENNEC_CACHE_DIR}"
mix compile --fennec_precompile
```

The following targets will be compiled:

- macOS
  - x86_64-macos
  - aarch64-macos
- Linux
  - x86_64-linux-gnu
  - x86_64-linux-musl
  - aarch64-linux-gnu
  - aarch64-linux-musl
  - riscv64-linux-musl
- Windows
  - x86_64-windows-gnu

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `fennec_precompile` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fennec_precompile, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/fennec_precompile>.

