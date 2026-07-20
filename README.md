# carven-xmake-repo

Xmake package repository and source rule for Carven.

Consumers use the packaged rule:

```lua
add_repositories("carven-xmake-repo https://github.com/ryblust/carven-xmake-repo.git")
add_requires("carven")

target("app")
    set_kind("binary")
    add_packages("carven")
    add_rules("@carven/carven")
    add_files("main.cv")
```

The rule passes every target `.cv` input to one deterministic Carven
invocation before compiling any generated C++. Source paths are relative to the
configured work directory and mirrored below xmake's target autogeneration
directory. A root-level `main.cv` generates `<autogendir>/main.cpp`, while
`src/app/main.cv` generates `<autogendir>/src/app/main.cpp`. Generated headers
are resolved through `<autogendir>`; input source directories are not added as
C++ include directories. Generated `.cpp` files are registered as ordinary
xmake C++ sources, so xmake owns compiler dependency scanning, compiler-option
invalidation, build caching, and incremental object compilation.

The rule derives Carven's output standard from the target's C++ language
configuration. A target without one receives C++20. Changing the effective
standard invalidates the batch transpile dependency.

Repository development can install only the packaged rules while supplying a
locally built compiler and runtime:

```lua
add_repositories("carven-xmake-repo https://github.com/ryblust/carven-xmake-repo.git")
add_requires("carven", {system = false, configs = {rules_only = true}})
```

Targets then apply `@carven/carven` and set `carven.program`,
`carven.includedir`, and, when the command should run outside the xmake project
directory, `carven.workdir`. The program, runtime header, and `.cv` inputs
participate in incremental dependency checks. `carven.workdir` must be an
ancestor of every configured source so the CLI receives stable relative module
paths. Removing any required generated `.cpp` causes the complete source batch
to be regenerated before incremental C++ compilation resumes.

To test unpublished package or rule changes from a Carven checkout, point that
checkout at this local repository and force xmake to reinstall the rules-only
package:

```shell
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake require --force
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake test
```

`CARVEN_XMAKE_REPO_DIR` is consumed by the Carven checkout, not by this package
repository. Without it, the Carven checkout uses the GitHub repository.

To validate a complete Carven package installation from a local Carven source
checkout, set `CARVEN_SOURCE_DIR` while using this package repository:

```shell
CARVEN_SOURCE_DIR=/path/to/carven xmake require --force carven
```

Without `CARVEN_SOURCE_DIR`, a complete package installation obtains the Carven
source from GitHub. Rules-only installations do not use Carven source and
therefore ignore `CARVEN_SOURCE_DIR`.

Complete package installation configures the Carven source build with
`build_tests=false`. The package only needs the `carven` executable and runtime
headers, so repository test targets and their rules-only package dependency are
excluded from package configuration. This also prevents the source build from
recursively requesting the rules-only variant of the package being installed.
