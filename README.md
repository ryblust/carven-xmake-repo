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
Xmake project directory and mirrored below xmake's target autogeneration
directory. A root-level `main.cv` generates `<autogendir>/main.cpp`, while
`src/app/main.cv` generates `<autogendir>/src/app/main.cpp`. Generated headers
are resolved through `<autogendir>`; input source directories are not added as
C++ include directories. Generated `.cpp` files are registered as ordinary
xmake C++ sources, so xmake owns compiler dependency scanning, compiler-option
invalidation, build caching, and incremental object compilation.

Generation runs as a prepare-phase job before xmake compiles generated C++.
Xmake's C++ named-module scanner also runs during the prepare phase and scans
ordinary `.cpp` consumers as well as module interface units. The `carven.build`
source-batch rule is therefore explicitly ordered before
`c++.build.modules.scanner`; placing that order on the façade rule does not
reliably add it to the source-batch prepare graph. Targets without C++ modules
disable the scanner, so the ordering edge is inactive there.

The target's C++ language configuration belongs entirely to xmake and its C++
toolchain; it is not passed to Carven. Carven-generated code requires at least
C++20. A target without an explicit C++ language receives C++20 from the rule;
an explicit lower or unsupported C++ standard is rejected during configuration.

Generated headers remain private to their target. Cross-target generated-header
publication and C++ module consumers are not part of the current `.hpp + .cpp`
integration contract.

Repository development can install only the packaged rules while supplying a
locally built compiler and runtime:

```lua
add_repositories("carven-xmake-repo https://github.com/ryblust/carven-xmake-repo.git")
add_requires("carven", {system = false, configs = {rules_only = true}})
```

Targets then apply `@carven/carven` and set `carven.program` plus the
single-root `carven.includedir` value. The compiler program, complete sorted
`.cv` input set, emission options, and path-only artifact receipt participate in
generation dependency checks. Generated C++ includes its runtime
and StandardCraft headers normally, so xmake's C++ dependency scanner owns
header invalidation. Removing any receipt-owned generated file causes the
complete source batch to be regenerated before incremental C++ compilation
resumes. A changed `.cv` still runs one complete Carven batch, while
content-identical artifacts retain their mtimes so downstream C++ compilation
only rebuilds units whose generated content changed. This is content-stable
incremental materialization, not compiler-level incremental analysis.
After each Carven invocation, a missing, malformed, or unreadable artifact
receipt fails generation instead of guessing which generated files the compiler
owns.

Inline-test targets use ordinary xmake target and test registration concepts:

```lua
target("app-test")
    set_kind("binary")
    add_packages("carven")
    add_rules("@carven/carven", {emit_tests = true})
    add_files("src/**.cv", "tests/**_test.cv")
    add_tests("default")
```

`emit_tests = true` passes `--emit-tests` and adds the generated default runner.
For a custom runner, also set `emit_test_main = false` and add the implementation
translation unit yourself. Setting `emit_test_main = false` without emitting tests
is rejected. The rule does not discover test files, create targets, or call
`add_tests`.

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
