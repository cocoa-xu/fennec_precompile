# FennecPrecompile

Drop-in library for `:elixir_make` that precompiles NIF binaries and pull NIF libraries.

This work is inspired ~~(massive copy-and-paste)~~ by [`rustler_precompiled`](https://github.com/philss/rustler_precompiled). However, this library is more focused on crosscompiling C/C++ projects using Zig as a Cross-compiler whereas `rustler_precompiled` is focused on crosscompiling Rust projects to NIF using Rust with [`rustler`](https://github.com/rusterlium/rustler).

## Usage
Remove the `:elixir_make` compiler from the `compilers` section:

```elixir
def project do
  [
    # ...
    compilers: Mix.compilers(),
    # ...
  ]
end
```

Precompiling happens when run `mix fennec.precompile`.
```elixir
# optional settings to override the default cache directory
export FENNEC_CACHE_DIR="$(pwd)/cache"

# precompile
mix fennec.precompile

# it's also possible to run `mix fennec.precompile` with other flags 
# other flags will be passed to `:elixir_make`
mix fennec.precompile --my-flag
```

What happens when you run `mix fennec.precompile`?

- `CC` will be set to `zig cc -target "ARCH-OS-ABI"`
- `CXX` will be set to `zig c++ -target "ARCH-OS-ABI"`
- `CPP` will be set to `zig c++ -target "ARCH-OS-ABI"`

Everything else is the same as when you run `mix compile` (with `:elixir_make`, or `mix compile.elixir_make`).

To fetch precompiled binaries, run `mix fennec.fetch`.
```elixir
# fetch all precompiled binaries
mix fennec.fetch --all
# fetch specific binaries
mix fennec.fetch --only-local

# print checksums
mix fennec.fetch --all --print
mix fennec.fetch --only-local --print
```

The following targets will be compiled by default:

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

## License

Copyright 2022 Cocoa Xu

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
