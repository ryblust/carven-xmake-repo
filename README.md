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
their application sources with ordinary Xmake target settings; they do not need
to create a local `crafts/` directory.

The rule requires Xmake 3.1.1 or newer. It passes every target `.cv` input to
one deterministic Carven invocation before compiling generated C++. Every
invocation passes `--explicit-inputs`, so the compiler uses exactly the source
batch selected by the rule. Inputs include installed `crafts/carven/` sources
and sources from an existing project-root `crafts/`. Carven writes into a disposable staging
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
external components it actually uses. Installed and project-root `crafts/`
directories are C++ include directories.
Other input source directories are not added as C++ include directories. Generated
`.cpp` files are registered as ordinary xmake C++ sources, so xmake owns compiler
dependency scanning, compiler-option invalidation, build caching, and incremental
object compilation.

Generation runs through `before_prepare_files`, xmake's job graph, and
`core.project.depend`. Xmake's C++ named-module scanner runs in the main prepare
phase and scans ordinary `.cpp` consumers as well as module interface units.
The prepare-stage boundary therefore guarantees that generated C++ and headers
exist before the scanner starts.

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

The compiler and its matching crafts are installed together at `bin/carven` and
`crafts/` below the package prefix. The rule obtains both locations from the
required package; consumers do not configure toolchain paths.

Generated interface components remain private to their target. The installed
standard library has a separate native object dependency.

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

## Installed standard library

The rule automatically compiles installed `crafts/carven` implementations and
native runtime sources into object dependencies. Targets share an object
dependency when their Carven installation, native compiler, toolchain, C++
compilation settings, and prerequisite targets match. Xmake supplies the effective
compiler flags, including language, macros, include paths, runtime, and
instruction-set settings. Configure these through ordinary target settings:

```lua
target("portable-app")
    set_kind("binary")
    add_defines("CARVEN_SIMD_FORCE_PORTABLE")
    add_rules("@carven/carven")
    add_files("main.cv")
```

Different compilation environments receive separate dependencies automatically.
The dependency uses the toolchain's shared-library compilation settings so its
objects can be consumed by executables and shared libraries. Project-local Crafts
remain application target inputs. The object dependency retains the consumer's
prerequisite targets. Generated headers therefore belong to producer targets
connected through ordinary `add_deps`. Precompiled-header source is included
with the library compilation; its compiled cache remains target-local.

Installed modules have a linkage domain independent of the application domain
and test mode. Each consumer analyzes the complete source batch and emits its
interfaces and requested inline static instances. The library dependency emits
installed implementations from its closed source batch, without inline tests or
an entry point. Xmake owns native compilation, dependency scanning, caching,
object reuse, and linking.

## Timing

Enable Carven timing reports:

```lua
add_rules("@carven/carven", {timings = true})
```

`timings` accepts a Boolean and defaults to disabled. It passes `--timings` to
Carven and forwards the invocation's stderr under its target name after exit.
Changing the option invalidates the generation dependency record. Reused
generation emits no report.

## Incremental generation

The compiler program, complete sorted `.cv` input set, invocation, installed rule
files, and live generated artifacts participate in generation dependency checks.
A source edit reruns each affected complete Carven batch. An installed-library
edit also invalidates consumers that analyze it. Missing generated artifacts
cause regeneration before native compilation resumes.

Generation writes to staging. A successful invocation removes obsolete live
files and promotes artifacts with `copy_if_different`; unchanged bytes preserve
mtimes. Failed generation leaves live output intact. Failed promotion leaves the
dependency record invalid so the next build repairs partial output. Xmake's C++
dependency scanner tracks included headers and rebuilds affected native objects.

## Inline tests

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
or call `add_tests`. It creates only the installed standard-library dependency.

## Local development

The compiler repository uses `rules_only = true` while building its own compiler.
The rule then uses the project's `carven` target and project-root `crafts/`.
Integration projects can set `carven.program` to a local compiler and
`carven.craftsdir` to its matching Crafts directory.

From a Carven checkout, install and exercise a local rules package:

```shell
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo ./xmakew require --force
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo ./xmakew f
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo ./xmakew build
CARVEN_XMAKE_REPO_DIR=/path/to/carven-xmake-repo ./xmakew test
```

Build the compiler before testing. Generation runs during Xmake preparation,
before target dependencies are built, so the compiler executable must already
be available. `CARVEN_XMAKE_REPO_DIR` selects the checkout's package repository;
omitting it selects the GitHub repository.

To install the complete package from local Carven source, use:

```shell
CARVEN_SOURCE_DIR=/path/to/carven xmake require --force carven
```

A complete installation builds the source project's `carven` target and installs
the compiler and production Crafts tree. Omitting `CARVEN_SOURCE_DIR` selects
GitHub source. Rules-only installations contain the build rule and require no
compiler source.
