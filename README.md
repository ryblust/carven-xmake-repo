# carven-xmake-repo

Xmake package repository and source rule for Carven.

Projects declare the external dependency and attach its rule to a target:

```lua
add_repositories("carven-xmake-repo https://github.com/ryblust/carven-xmake-repo.git")
add_requires("carven")

target("app")
    set_kind("binary")
    add_rules("@carven/carven")
    add_files("main.cv")
```

The rule configures the compiler and Crafts paths automatically. Projects list
their application sources with ordinary Xmake target settings.

The rule requires Xmake 3.0.4 or newer. It passes every target `.cv` input to
one deterministic Carven invocation before compiling generated C++. The target's
inputs include the `.cv` sources from the installed toolchain `crafts/carven/` and an
existing project-root `crafts/`. Carven writes into a disposable staging
directory; Xmake promotes the result into the
target-private live root `<autogendir>/rules/carven`. Application source paths
are relative to the Xmake project directory and mirrored below that root. Installed
craft sources are passed as absolute filenames. Their paths from the `crafts/`
component are preserved below the generated directory. A root-level
`main.cv` generates `<live-root>/main.cpp`, while `src/app/main.cv` generates
`<live-root>/src/app/main.cpp`. Published semantic surfaces are emitted as
target-private component headers below the reserved `carven/generated/` include
hierarchy, such as `<live-root>/carven/generated/src/app/main.hpp`. Each generated
implementation includes its own surface component, when present, and the
external components it actually uses. The installed and project-root `crafts/` directories are C++ include directories.
Other input source directories are not added as C++ include directories. Generated
`.cpp` files are registered as ordinary xmake C++ sources, so xmake owns compiler
dependency scanning, compiler-option invalidation, build caching, and incremental
object compilation.

Generation runs through `before_prepare_files`, xmake's job graph, and
`core.project.depend`. Xmake's C++ named-module scanner runs in the main prepare
phase and scans ordinary `.cpp` consumers as well as module interface units.
The prepare-stage boundary therefore guarantees that generated C++ and headers
exist before the scanner starts, without coupling the packaged rule to the
scanner's internal rule name or translating generation into batch commands.

The target's C++ language configuration belongs entirely to xmake and its C++
toolchain; it is not passed to Carven. Carven-generated code requires at least
C++20. A target without an explicit C++ language receives C++20 from the rule.
An explicit language remains the target's choice and is diagnosed by its C++
toolchain if it cannot compile the generated code.

A craft is a source package in a `crafts/` directory. The rule uses Xmake's native
file matching to add `.cv` and optional `.cpp` files from both craft roots.
A source set change changes the compiler
invocation and generated source list; source edits and native header dependencies
use the existing generation and C++ dependency tracking. Duplicate module paths
are compiler errors, including conflicts between project and installed crafts.

Users list only application sources in `add_files`.
The compiler and its matching crafts are installed together at `bin/carven` and
`crafts/` below the package prefix. The rule obtains both locations from the
required package; consumers do not configure toolchain paths.

Generated interface components remain private to their target. Cross-target
generated header publication and C++ module consumers are not part of the
integration contract.

The rule passes a stable linkage domain on every compiler invocation. Its
default is the normalized absolute project directory plus `target:fullname()`,
so source edits do not rename generated C++ entities while two Xmake targets
compiling the same canonical module paths do not collide when linked into one
process. A caller that needs identity to survive checkout relocation can
replace the domain value explicitly:

```lua
add_rules("@carven/carven", {linkage_domain = "my-project:stable-domain"})
```

The domain value and all other compiler arguments participate in the generation
dependency values; changing it regenerates the batch.

The compiler repository uses `rules_only = true` while building its own compiler.
In this mode, the rule uses the project's `carven` target and project-root
`crafts/`. Integration projects can reuse the same rules package and set
`carven.program` to a local compiler and `carven.craftsdir` to its matching
`crafts/` directory. Consumer projects normally use the complete package.

The compiler program,
complete sorted `.cv` input set, full invocation, installed rule file, and every live generated artifact
participate in generation dependency checks. Generated C++ includes its runtime
and interface components normally, so
xmake's C++ dependency scanner discovers the component graph and owns header
invalidation. Removing any generated file causes the complete
source batch to be regenerated before incremental C++ compilation resumes. A
changed `.cv` still runs one complete Carven batch, while content-identical
artifacts retain their mtimes so downstream C++ compilation only rebuilds units
whose generated content changed. This is content-stable incremental
materialization, not compiler-level incremental analysis. After successful
generation, Xmake removes only live files absent from staging, then promotes
each staged file with `copy_if_different`. Unchanged files retain their mtimes
even when other artifacts are added or removed. Empty directories that conflict
with a new file are removed before promotion. A failed Carven invocation discards staging
without modifying live output. A failed promotion leaves the dependency cache
invalid so the next build repairs any partial update. Changing only the
installed rule file also invalidates the generation job.

Inline-test targets use ordinary xmake target and test registration concepts:

```lua
target("app-test")
    set_default(false)
    set_kind("binary")
    add_rules("@carven/carven", {tests = "default"})
    add_files("src/**.cv", "tests/**_test.cv")
    add_tests("default")
```

`tests = "default"` emits inline tests, the generated runner header, and the
generated entry. `tests = "external"` emits inline tests and the generated
runner header without a generated entry; the target supplies its own process
entry, which may be an ordinary C++ source added with `add_files` or a Carven
`main`. Omitting `tests` emits no tests. These are the only accepted modes. The
rule does not discover test files, copy or compile an external entry path,
create targets, or call `add_tests`.

To test unpublished package or rule changes from a Carven checkout, point that
checkout at this local repository and force xmake to reinstall the rules-only
package:

```shell
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake require --force
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake f
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake build
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo xmake test
```

The rule-contract smoke lives in the Carven checkout and runs the locally built
compiler with the locally installed packaged rule. It protects the current
build invariants defined above; package-repository layout is not part of that
contract.

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

A complete installation selects the source project's `carven` target and
installs the compiler and complete production crafts tree.
