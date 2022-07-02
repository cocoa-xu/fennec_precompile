# Precompilation guide
`:fennec_precompile` aims to be a drop-in replacement for `:elixir_make`. It provides a convenient way to precompile your NIF app for all the supported platforms. This is mostly useful for the following reasons:

1. when a working C/C++ toolchain is not available (e.g, running livebook on some embedded devices, or running in nerves environment, where a C/C++ compiler is not included)
2. a working C/C++ compiler won't be a strict requirement for using your NIF app.
3. save time on compiling.

In the following sections, I will walk you through how to use `:fennec_precompile` to precompile an example app, `:fennec_example`.

## Create a new app
We start by creating a new app, say `fennec_precompile`.

```shell
$ mix new fennec_example
* creating README.md
* creating .formatter.exs
* creating .gitignore
* creating mix.exs
* creating lib
* creating lib/fennec_example.ex
* creating test
* creating test/test_helper.exs
* creating test/fennec_example_test.exs

Your Mix project was created successfully.
You can use "mix" to compile it, test it, and more:

    cd fennec_example
    mix test

Run "mix help" for more commands.
```

## Add `:fennec_precompile` to the `mix.exs`
In the `mix.exs` file, we add `:fennec_precompile` to `deps`. Also, note that `:fennec_precompile` should not be added to the `:compilers` list.

```elixir
defmodule FennecExample do
  use Mix.Project

  @version "0.1.0"
  def project do
    [
        # ...
        compilers: [:fennec_precompile] ++ Mix.compilers()
        fennec_base_url: "https://github.com/cocoa-xu/fennec_example/downloads/releases/v#{@version}",
        fennec_nif_filename: "nif"
        # ...
    ]
  end

  def deps do
    [
        # ...
        {:fennec_precompile, "~> 0.1"}
        # ...
    ]
  end
end
```

## Write NIF code
Then we write a toy NIF function that returns `'hello world'`.

```shell
$ mkdir -p c_src
$ cat <<EOF | tee c_src/fennec_example.c
#include <stdio.h>
#include <erl_nif.h>

static ERL_NIF_TERM hello_world(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    return enif_make_string(env, "hello world", ERL_NIF_LATIN1);
}

static ErlNifFunc nif_funcs[] =
{
    {"hello_world", 0, hello_world, 0}
};

ERL_NIF_INIT(fennec_example, nif_funcs, NULL, NULL, NULL, NULL);
EOF

# note that here the output file is named as `nif.so`
$ cat <<EOF | tee Makefile
PRIV_DIR = \$(MIX_APP_PATH)/priv
NIF_SO = \$(PRIV_DIR)/nif.so
C_SRC = \$(shell pwd)/c_src

CFLAGS += -shared -std=c11 -O3 -fPIC -I\$(ERTS_INCLUDE_DIR)
UNAME_S := \$(shell uname -s)
ifeq (\$(UNAME_S),Darwin)
	CFLAGS += -undefined dynamic_lookup -flat_namespace -undefined suppress
endif

.DEFAULT_GLOBAL := build

build: \$(NIF_SO)

\$(NIF_SO): \$(C_SRC)/fennec_example.c
	@ mkdir -p \$(PRIV_DIR)
	\$(CC) \$(CFLAGS) \$(C_SRC)/fennec_example.c -o \$(NIF_SO)
EOF

# `nif_filename` is set to `nif`, which is the name of the NIF file excluding the extension.
$ cat <<EOF | tee lib/fennec_example.ex
defmodule :fennec_example do
  @moduledoc false

  @on_load :load_nif
  def load_nif do
    nif_file = '#{:code.priv_dir(:fennec_example)}/nif'

    case :erlang.load_nif(nif_file, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> IO.puts("Failed to load nif: #{reason}")
    end
  end

  def hello_world(), do: :erlang.nif_error(:not_loaded)
end
EOF

$ cat <<EOF | tee test/fennec_example_test.ex
defmodule FennecExampleTest do
  use ExUnit.Case

  test "greets the world" do
    assert :fennec_example.hello_world() == 'hello world'
  end
end
EOF
```

In the `mix.exs` file, we passed two options: 

- `:fennec_base_url`. Required. Specifies the base download URL of the precompiled binaries. 
- `:fennec_nif_filename`. Required. Specifies the name of the precompiled binary file, excluding the file extension.

For all available options, please refer to [Mix.Tasks.Fennec.Precompile](Mix.Tasks.Fennec.Precompile.html).

All of these values can be overridden by the user in the `config/config.exs` file. For instance,

To avoid supply chain attack or to speed up the deployment, the user can redirect to their trusted server.

```elixir
import Config

config :fennec_precompile, :config, fennec_example: [
    fennec_base_url: "https://cdn.example.com/fennec_example",
    fennec_force_build: false
]
```

## (Optional) Test the NIF code locally
To test the NIF code locally, first we need to compile for the host platform.

```shell
# this is equivalent to `mix compile.elixir_make`
$ mix compile.fennec_precompile
==> fennec_example
cc -shared -std=c11 -O3 -fPIC -I/usr/local/lib/erlang/erts-13.0/include -undefined dynamic_lookup -flat_namespace -undefined suppress /Users/cocoa/Git/fennec_example/c_src/fennec_example.c -o /Users/cocoa/Git/fennec_example/_build/dev/lib/fennec_example/priv/nif.so
```

Of course, you can also use zig as the C/C++ compiler<sup>[1](#notes)</sup>.
```shell
# set environment variable `FENNEC_PRECOMPILE_ALWAYS_USE_ZIG` to `true`
$ export FENNEC_PRECOMPILE_ALWAYS_USE_ZIG=true
$ mix compile

20:42:07.566 [debug] Current compiling target: aarch64-macos
gcc -arch arm64 -shared -std=c11 -O3 -fPIC -I/usr/local/lib/erlang/erts-13.0/include -undefined dynamic_lookup -flat_namespace -undefined suppress /Users/cocoa/Git/fennec_example/c_src/fennec_example.c -o /Users/cocoa/Git/fennec_example/_build/dev/lib/fennec_example/priv/nif.so

20:42:07.678 [debug] Creating precompiled archive: /Users/cocoa/Library/Caches/fennec_precompiled/fennec_example-nif-2.16-aarch64-macos-0.1.0.tar.gz

20:42:07.733 [debug] Restore NIF for current node from: /Users/cocoa/Library/Caches/fennec_precompiled/aarch64-macos.tar.gz
```

After the compilation, you can test the NIF code locally.

```shell
$ mix test
.

Finished in 0.01 seconds (0.00s async, 0.01s sync)
1 test, 0 failures

Randomized with seed 145253
```

## (Optional) Test precompiling locally
To test precompiling on a local machine, run `mix fennec.precompile`.

```shell
$ export FENNEC_CACHE_DIR="$(pwd)/cache"
$ mix fennec.precompile
==> fennec_precompile
Compiling 1 file (.ex)

00:25:27.161 [debug] Current compiling target: x86_64-macos
==> fennec_example
gcc -arch x86_64 -shared -std=c11 -O3 -fPIC -I/usr/local/lib/erlang/erts-13.0/include -undefined dynamic_lookup -flat_namespace -undefined suppress /Users/cocoa/Git/fennec_example/c_src/fennec_example.c -o /Users/cocoa/Git/fennec_example/_build/dev/lib/fennec_example/priv/nif.so

00:25:27.237 [debug] Creating precompiled archive: /Users/cocoa/Git/fennec_example/cache/fennec_example-nif-2.16-x86_64-macos-0.1.0.tar.gz

00:25:27.286 [debug] Current compiling target: x86_64-linux-gnu
zig cc -target x86_64-linux-gnu -shared -std=c11 -O3 -fPIC -I/usr/local/lib/erlang/erts-13.0/include -undefined dynamic_lookup -flat_namespace -undefined suppress /Users/cocoa/Git/fennec_example/c_src/fennec_example.c -o /Users/cocoa/Git/fennec_example/_build/dev/lib/fennec_example/priv/nif.so

00:25:27.346 [debug] Creating precompiled archive: /Users/cocoa/Git/fennec_example/cache/fennec_example-nif-2.16-x86_64-linux-gnu-0.1.0.tar.gz

...
```

Precompiled binaries are stored in the `cache` subdirectory of the current directory.
```shell
ls -lah ${FENNEC_CACHE_DIR}
total 72
drwxr-xr-x  11 cocoa  staff   352B  1 Jul 23:17 .
drwxr-xr-x  20 cocoa  staff   640B  2 Jul 00:23 ..
-rw-r--r--   1 cocoa  staff   1.0K  2 Jul 00:25 fennec_example-nif-2.16-aarch64-linux-gnu-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   994B  2 Jul 00:25 fennec_example-nif-2.16-aarch64-linux-musl-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   1.3K  2 Jul 00:25 fennec_example-nif-2.16-aarch64-macos-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   977B  2 Jul 00:25 fennec_example-nif-2.16-riscv64-linux-musl-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   1.0K  2 Jul 00:25 fennec_example-nif-2.16-x86_64-linux-gnu-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   976B  2 Jul 00:25 fennec_example-nif-2.16-x86_64-linux-musl-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   989B  2 Jul 00:25 fennec_example-nif-2.16-x86_64-macos-0.1.0.tar.gz
-rw-r--r--   1 cocoa  staff   4.5K  2 Jul 00:25 fennec_example-nif-2.16-x86_64-windows-gnu-0.1.0.tar.gz
drwxr-xr-x   3 cocoa  staff    96B  1 Jul 20:49 metadata
```

## Setup GitHub Actions
For this guide the workflow file is located at [.github/workflows/fennec_precompile.yml](.github/workflows/fennec_precompile.yml)

```yml
name: precompile

on:
  push:
    tags:
      - 'v*'
    branches:
      - main

jobs:
  precompile:
    runs-on: macos-11
    env:
      MIX_ENV: "dev"

    steps:
      - uses: actions/checkout@v3

      - name: Install Erlang/OTP, Elixir and Zig
        run: |
          brew install erlang elixir zig
          mix local.hex --force
          mix local.rebar --force

      - name: Create precompiled library
        run: |
          export FENNEC_CACHE_DIR=$(pwd)/cache
          mkdir -p "${FENNEC_CACHE_DIR}"
          mix deps.get
          mix fennec.precompile

      - uses: softprops/action-gh-release@v1
        if: startsWith(github.ref, 'refs/tags/')
        with:
          files: |
            cache/*.tar.gz
            checksum-*.exs
```

The example here uses `macos-11` as the runner because it can generate binaries for most targets.

## Fetch precompiled binaries
After CI has finished, you can fetch the precompiled binaries from GitHub.

```shell
$ mix fennec.fetch --all --print
```

Meanwhile, a checksum file will be generated. In this example, the checksum file will be named as `checksum-fennec_example.exs`. 

This checksum file is extremely important in the scenario where you need to release a Hex package using precompiled NIFs. It's **MANDATORY** to include this file in your Hex package (by updating the `files` field in the `mix.exs`). Otherwise your package **won't work**.

```elixir
defp package do
  [
    files: [
      "lib",
      "checksum-*.exs",
      "mix.exs",
      # ...
    ],
    # ...
  ]
end
```

However, there is no need to track the checksum file in your version control system (git or other).

## Recommended flow
To recap, the suggested flow is the following:

1. Add `:fennec_precompile` and relevant `fennec_*` options to the `mix.exs`.
2. (Optional) Test if your library compiles locally.
    ```shell
    mix compile
    ```

3. (Optional) Test if your library can precompile to all specified targets locally.
    ```shell
    mix fennec.precompile
    ```

4. Precompile your library on CI.
    ```shell
    git push origin main --tags
    ```

5. Fetch precompiled binaries from GitHub.
    ```shell
    mix fennec.fetch --all --print
    ```

6. Update Hex package to include the checksum file.
7. Release the package to Hex.pm (make sure your release includes the correct files).

## Notes
1. `zig` seems to not like the `-undefined dynamic_lookup` and `-flat_namespace` flag on macOS. Using `zig` on macOS will cause the build to fail. This is mostly an upstream issue/bug.

```shell
zig cc -target aarch64-macos -shared -std=c11 -O3 -fPIC -I/usr/local/lib/erlang/erts-13.0/include -L/usr/local/lib/erlang/usr/lib -undefined dynamic_lookup -flat_namespace -undefined suppress /Users/cocoa/Git/fennec_example/c_src/fennec_example.c -o /Users/cocoa/Git/fennec_example/_build/dev/lib/fennec_example/priv/nif.so
error(link): undefined reference to symbol '_enif_make_string'
error(link):   first referenced in '/Users/cocoa/.cache/zig/o/a5316e27e5bd064608113ea75cd212c5/fennec_example.o'
error: UndefinedSymbolReference
make: *** [/Users/cocoa/Git/fennec_example/_build/dev/lib/fennec_example/priv/nif.so] Error 1
```
