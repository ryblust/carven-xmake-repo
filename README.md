# carven-xmake-repo

Xmake package repository for the Carven compiler and its `.cv` source rule.
Requires Xmake 3.1.1 or later and a C++20-capable toolchain.

Declare the package and attach its rule to a target:

```lua
add_repositories("carven-xmake-repo https://github.com/ryblust/carven-xmake-repo.git")
add_requires("carven")

target("app")
    set_kind("binary")
    add_rules("@carven/carven")
    add_files("main.cv")
```

Select sources with `add_files` and configure native compilation through Xmake
target and file settings. The rule includes installed Crafts and a project-root
`crafts/` directory when present.

For local rule development, run this from a Carven checkout:

```shell
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo ./xmakew require --force
```

Build the compiler with `./xmakew build` before running `./xmakew test`.
Use `CARVEN_SOURCE_DIR=/path/to/carven` when installing the complete package
from local compiler sources.

[Carven project](https://github.com/ryblust/carven) ·
[Package definition](packages/c/carven/xmake.lua) ·
[Source rule](packages/c/carven/rules/carven/xmake.lua)
