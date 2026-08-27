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

The rule passes every target `.cv` input to one deterministic Carven invocation
with `--output-dir <autogendir>` before compiling generated C++. Source
paths are relative to the Xmake project directory and mirrored below xmake's
target autogeneration directory. A root-level `main.cv` generates
`<autogendir>/main.cpp`, while `src/app/main.cv` generates
`<autogendir>/src/app/main.cpp`. Published semantic surfaces are emitted as
target-private component headers at the lexicographically first source anchor,
such as `<autogendir>/src/app/main.carven-interface.hpp`. Each generated
implementation includes its own surface component, when present, and the
external components it actually uses. Input source directories are not added
as C++ include directories. Generated `.cpp` files are registered as ordinary
xmake C++ sources, so xmake owns compiler dependency scanning, compiler-option
invalidation, build caching, and incremental object compilation.

Generation runs through `before_prepare_files`, xmake's job graph, and
`core.project.depend`. Xmake's C++ named-module scanner runs in the main prepare
phase and scans ordinary `.cpp` consumers as well as module interface units.
The prepare-stage boundary therefore guarantees that generated C++ and headers
exist before the scanner starts, without coupling the packaged rule to the
scanner's internal rule name or translating generation into batch commands.

The target's C++ language configuration belongs entirely to xmake and its C++
toolchain; it is not passed to Carven. Carven-generated code requires at least
C++20. A target without an explicit C++ language receives C++20 from the rule;
an explicit lower or unsupported C++ standard is rejected during configuration.

Generated interface components remain private to their target. Cross-target
generated header publication and C++ module consumers are not part of the
integration contract.

The rule passes a stable linkage domain on every compiler invocation. Its
default is the normalized absolute project directory plus `target:fullname()`,
so source edits do not rename generated C++ entities while two Xmake targets
compiling the same canonical module paths do not collide when linked into one
process. A caller that needs identity to survive checkout relocation can
replace the domain key explicitly:

```lua
add_rules("@carven/carven", {linkage_domain = "my-project:stable-domain"})
```

The domain key and all other compiler arguments participate in the generation
dependency values; changing it regenerates the batch.

Repository development can install only the packaged rules while supplying a
locally built compiler and runtime:

```lua
add_repositories("carven-xmake-repo https://github.com/ryblust/carven-xmake-repo.git")
add_requires("carven", {system = false, configs = {rules_only = true}})
```

Targets then apply `@carven/carven` and set `carven.program` plus the single-root
`carven.includedir` value. The compiler program, complete sorted `.cv` input
set, full invocation, receipt schema, installed rule file, path-only receipt,
and every generated artifact participate in generation dependency checks.
Generated C++ includes its runtime and interface components normally, so
xmake's C++ dependency scanner discovers the component graph and owns header
invalidation. Removing any receipt-owned generated file causes the complete
source batch to be regenerated before incremental C++ compilation resumes. A
changed `.cv` still runs one complete Carven batch, while content-identical
artifacts retain their mtimes so downstream C++ compilation only rebuilds units
whose generated content changed. This is content-stable incremental
materialization, not compiler-level incremental analysis. After each Carven
invocation, a missing, malformed, unreadable, unsorted, or otherwise invalid
receipt fails generation instead of guessing which generated files the
compiler owns. Changing only the installed rule file also invalidates the
generation job.

Inline-test targets use ordinary xmake target and test registration concepts:

```lua
target("app-test")
    set_kind("binary")
    add_packages("carven")
    add_rules("@carven/carven", {tests = "default"})
    add_files("src/**.cv", "tests/**_test.cv")
    add_tests("default")
```

`tests = "default"` emits inline tests and registers Carven's generated runner.
`tests = "external"` emits inline tests without a runner; the target supplies an
ordinary C++ runner with `add_files`. Omitting `tests` emits no tests. These are
the only accepted modes. The rule does not discover test files, copy or compile a
runner path, create targets, or call `add_tests`.

To test unpublished package or rule changes from a Carven checkout, point that
checkout at this local repository and force xmake to reinstall the rules-only
package:

```shell
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake require --force
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake f
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake build
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake test
```

The build step before testing is required. Generation runs in Xmake's prepare
phase so named-module scanning can consume generated files; a compiler target
from the same project cannot be built early enough by an ordinary target
dependency.

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
`build_tests=n`. The package only needs the `carven` executable and runtime
headers, so repository test targets and their rules-only package dependency are
excluded from package configuration. This also prevents the source build from
recursively requesting the rules-only variant of the package being installed.
