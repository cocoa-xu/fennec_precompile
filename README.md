# FennecPrecompile

Drop-in library for `:elixir_make` for precompiling NIF binaries with Zig as the cross-compiler.

This work is inspired by ~~(massively copy-and-paste from)~~ [`rustler_precompiled`](https://github.com/philss/rustler_precompiled). However, this library is more focused on crosscompiling C/C++ projects using Zig as a cross-compiler whereas `rustler_precompiled` is focused on crosscompiling Rust projects to NIF using Rust with [`rustler`](https://github.com/rusterlium/rustler).

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `fennec_precompile` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fennec_precompile, "~> 0.1.1"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/fennec_precompile>.

## Usage
Replace the `:elixir_make` compiler with `:fennec_precompile` in the `compilers` section:

```elixir
def project do
  [
    # ...
    compilers: [:fennec_precompile] ++ Mix.compilers(),
    # ...
  ]
end
```

A table of supported environment variables, their scopes and examples can be found in the [`Enviroment Variable`](#environment-variable) section.

## Precompile NIFs
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

A full list of supported targets can be found using `zig targets`.

It's worth noting that some targets may not successfully compile on certain platforms. For example, `x86_64-macos` will not compile on Linux and `x86_64-windows-msvc` will not compile on macOS.

### Specifying targets to compile
To compile for a specific target/a list of targets, set the `FENNEC_PRECOMPILE_TARGETS` environment variable.

```elixir
# for example, to compile for aarch64-linux-musl,riscv64-linux-musl
export FENNEC_CACHE_DIR="$(pwd)/cache"
export FENNEC_PRECOMPILE_TARGETS="aarch64-linux-musl,riscv64-linux-musl"
mix fennec.precompile
```

## Fetch Precompiled Binaries
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

## Use zig for native build
This section only relates to the behaviour of the `mix compile` and `mix compile [--args] ...` commands after replacing the `:elixir_make` compiler with `:fennec_precompile`.

For native build, `zig` is not used by default for two reasons. 

1. For users who are only interested in using the app their native host, it is not necessary to compile the app using Zig.
2. As this tool aim to be a drop-in replacement for `:elixir_make`, the default behaviour of `mix compile` and `mix compile [--args] ...` of this tool is the same as what would be expected with `:elixir_make`.

However, you can choose to always use `zig` as the compiler by setting environment variable `FENNEC_PRECOMPILE_ALWAYS_USE_ZIG` to `true`.

To be more specific, by default, the environment variables `CC`, `CXX` and `CPP` will not be changed by this tool when running `mix compile` or `mix compile [--args] ...`. When `FENNEC_PRECOMPILE_ALWAYS_USE_ZIG` is `true`, the compiled NIF binaries (for the native host, identified as `ARCH-OS-ABI`) should be the same as the one generated by `mix fennec.precompile`.

For example, when running `mix compile` or `mix compile [--args]` on arm64 macOS with this option set to `true`, files in the `_build/${MIX_ENV}/lib/my_app/priv` directory should match the ones in the `my_app-nif-NIF_VERSION-aarch64-macos-VERSION.tar.gz` generated by `mix fennec.precompile`.

To install Zig from a package manager, please refer to the officail guide from zig, [Install Zig from a Package Manager](https://github.com/ziglang/zig/wiki/Install-Zig-from-a-Package-Manager).

## Where is the precompiled binaries?
The path of the cache directory is determined in the following order:

  1. `FENNEC_CACHE_DIR`
  2. `:filename.basedir(:user_cache, "fennec_precompiled", ...)`

If the environment variable `FENNEC_CACHE_DIR` is set, the cache directory will be `$FENNEC_CACHE_DIR`. Otherwise, the cache directory will be determined by the following function:

```elixir
cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
:filename.basedir(:user_cache, "fennec_precompiled", cache_opts)
```

## Environment Variable
- `FENNEC_CACHE_DIR`

  This optional environment variable is used in both compile-time and runtime. It is used to specify the location of the cache directory.

  During compile-time, the cache directory is used to store the precompiled binaries when running `mix fennec.precompile`. When running `mix fennec.fetch`, the cache directory is used to save the downloaded binaries.

  In runtime, the cache directory is used to store the downloaded binaries.

  For example,

  ```shell
  # store precompiled binaries in the "cache" subdirectory of the current directory
  export FENNEC_CACHE_DIR="$(pwd)/cache"
  mix fennec.precompile
  ```

- `FENNEC_PRECOMPILE_TARGETS`
  
  Only used when running `mix fennec.precompile`. This environment variable is mostly used in CI or temporarily  specify the target(s) to compile. 
  
  It is a comma separated list of targets to compile. For example,
  
  ```shell
  export FENNEC_PRECOMPILE_TARGETS="aarch64-linux-musl,riscv64-linux-musl"
  mix fennec.precompile
  ```

  If `FENNEC_PRECOMPILE_TARGETS` is not set, the `fennec_precompile` will then check `config/config.exs` to see if there is a `:targets` key for `my_app`. If there is, the value of the key will be the targets.

  ```elixir
  import Config

  config :fennec_precompile, :config, my_app: [
    targets: ["aarch64-linux-musl", "riscv64-linux-musl"]
  ]
  ```

  Please note that setting `:targets` in the `use`-clause is only visible to the runtime and is invisble to the `mix fennec.precompile` command. 

  ```elixir
    use FennecPrecompile,
      # ...
      targets: ["aarch64-linux-musl", "riscv64-linux-musl"]
  ```

  `:targets` in the `use`-clause will only be used in the following cases:

    1. `:force_build` is set to `true`. In this case, the `:targets` acts as a list of compatible targets in terms of the source code. For example, NIFs that are specifically written for ARM64 Linux will fail to compile for other OS or CPU architeture. If the source code is not compatible with the current node, the build will fail.
    2. `:force_build` is set to `false`. In this case, the `:targets` acts as a list of available targets of the precompiled binaries. If there is no match with the current node, no precompiled NIF will be downloaded and the app will fail to start.

- `FENNEC_PRECOMPILE_ALWAYS_USE_ZIG`

  Only used when running `mix compile` or `mix compile [--args] ...`. 
  
  It is a boolean value. When set to `true`, `zig` will be used as the compiler instead of the default `$CC`, `$CXX` or `$CPP`. For more information, please refer to the section above, [Use zig for native build](#use-zig-for-native-build).

  ```shell
  # this is the default, equivalent to run `mix compile` with `:elixir_make`
  unset FENNEC_PRECOMPILE_ALWAYS_USE_ZIG
  mix compile

  # this will force using zig as the compiler
  export FENNEC_PRECOMPILE_ALWAYS_USE_ZIG=true
  mix compile
  ```

- `FENNEC_PRECOMPILE_OTP_APP`

  This is an optional environment variable. It is only used when running `mix fennec.precompile` and `mix fennec.fetch`. The default value is `Mix.Project.config()[:app]`.

  This environment variable is used to specify the name of the OTP/Elixir application if you want it to be different from the `:app` set in the `mix.exs` file.

  For example, if you want to use the name `app1` instead of the name `my_app` (which was set in `mix.exs` file of `my_app`), you can set `FENNEC_PRECOMPILE_OTP_APP` to `app1`. The precompiled binaries will be saved as `app1-nif-NIF_VERSION-ARCH-OS-ABI-VERSION.tar.gz`.

  This also affects the behaviour of the `mix fennec.fetch` command. If you want to fetch the precompiled binaries using the name `app1`, you can set `FENNEC_PRECOMPILE_OTP_APP` to `app1` and run `mix fennec.fetch`. Then this tool will download the precompiled binaries using the name `app1-nif-NIF_VERSION-ARCH-OS-ABI-VERSION.tar.gz`.

  Please note that the `FENNEC_PRECOMPILE_OTP_APP` environment variable shoud match the `otp_app` field in the `use`-clause in corresponding module file. For example,

  ```shell
  # overwrite default name with "app1"
  export FENNEC_PRECOMPILE_OTP_APP=app1
  mix fennec.precompile
  ```

  ```elixir
  defmodule MyApp do
    # `otp_app` should match the value of `FENNEC_PRECOMPILE_OTP_APP`
    use FennecPrecompile,
      otp_app: :app1,
      base_url: "https://github.com/me/my_project/releases/download/v0.1.0",
      version: "0.1.0"
  end
  ```

- `FENNEC_PRECOMPILE_VERSION`

  This one is similar to `FENNEC_PRECOMPILE_OTP_APP`. It is only used when running `mix fennec.precompile` and `mix fennec.fetch`. The default value is `Mix.Project.config()[:version]`.

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
