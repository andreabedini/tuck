# Example: building a C project with Tuck

A small, self-contained Tuck repository that models a real C build: a static
library and an executable that links against it. It exists to show what Tuck
produces from `BUILD` files today — the **target graph** and the **action
graph** — on a project more meaningful than the unit-test fixtures.

> **Scope.** Tuck currently implements the *loading* and *analysis* phases. It
> works out *what* to build and emits the exact commands that would do it, but
> it does **not run them yet** — execution is a future milestone. So this
> example stops at inspecting the graphs; the `cc`/`ar` command lines below are
> the deliverable, not a built binary. They are real, runnable invocations
> (you can copy them into a shell), but Tuck does not invoke them for you.

## Layout

```
example/
  .tuck/            # repo-root marker (Tuck walks up to find this)
  TUCK              # repo-global rule definitions: cc_library, cc_binary
  lib/greet/
    BUILD           # cc_library greet
    greet.h
    greet.c         # greet(name) -> prints "Hello, <name>!"
  app/
    BUILD           # cc_binary hello, depends on //lib/greet:greet
    main.c          # calls greet()
```

Two packages (`lib/greet` and `app`) with one dependency edge between them:
`//app:hello` depends on `//lib/greet:greet`.

## The rules

Rules live only in the root `TUCK` file. This example defines two, in the style
of Buck/Bazel `cc_*` rules:

- **`cc_library`** — compiles each C source to an object file, then bundles the
  objects into a static archive (`ar rcs`). The archive is the library's single
  public output, so a dependent that calls `ctx dep_outputs` sees exactly one
  artifact to link against.
- **`cc_binary`** — compiles its own sources, then links the resulting objects
  together with the static archive of every dependency into an executable.

Each rule's `impl` body emits actions during analysis using the `ctx` command
(`ctx attr`, `ctx declare_output`, `ctx action`, `ctx dep_outputs`). Because the
rules interpreter is sandboxed (`file` is unavailable), the small path helpers
at the top of `TUCK` use plain string operations. See `TUCK` for the details.

## Inspecting the build

Run these from inside `example/` (Tcl 9+):

### Targets

List every target in the repo:

```console
$ tclsh ../tuck.tcl targets //...
//app:hello
//lib/greet:greet
```

### Dependencies (leaves first)

```console
$ tclsh ../tuck.tcl query deps //app:hello
//lib/greet:greet
//app:hello
```

### The action graph

`analyze` runs the analysis phase over the target and its closure and prints
every action, leaves first. This is the heart of the example — the concrete
compile/archive/link commands Tuck derived from the `BUILD` files:

```console
$ tclsh ../tuck.tcl analyze //app:hello
//lib/greet:greet#0
  inputs:  source:lib/greet/greet.c source:lib/greet/greet.h
  outputs: build/greet.o
  cmd:     cc -c lib/greet/greet.c -o build/greet.o
//lib/greet:greet#1
  inputs:  build/greet.o
  outputs: declared://lib/greet:greet:build/libgreet.a
  cmd:     ar rcs build/libgreet.a build/greet.o
//app:hello#0
  inputs:  source:app/main.c
  outputs: build/main.o
  cmd:     cc -Ilib/greet -c app/main.c -o build/main.o
//app:hello#1
  inputs:  build/main.o declared://lib/greet:greet:build/libgreet.a
  outputs: declared://app:hello:build/hello
  cmd:     cc build/main.o build/libgreet.a -o build/hello
```

Reading the graph:

- Each action is `<label>#<n>`. Inputs and outputs are *artifacts*: `source:…`
  for files in the repo, `declared:<label>:<relpath>` for outputs a rule
  declared. Intermediate object files appear as plain paths.
- The order is the build order. `//lib/greet:greet` is fully compiled and
  archived before `//app:hello` links against it — that is the leaves-first
  guarantee analysis relies on so `ctx dep_outputs` always sees a dependency's
  outputs.
- The four `cmd:` lines, run top to bottom from this directory with a C
  toolchain installed, would produce `build/hello`. Tuck does not run them yet.

### Actions for a single target

`query actions` restricts the dump to one target (no dependencies):

```console
$ tclsh ../tuck.tcl query actions //app:hello
//app:hello#0
  inputs:  source:app/main.c
  outputs: build/main.o
  cmd:     cc -Ilib/greet -c app/main.c -o build/main.o
//app:hello#1
  inputs:  build/main.o declared://lib/greet:greet:build/libgreet.a
  outputs: declared://app:hello:build/hello
  cmd:     cc build/main.o build/libgreet.a -o build/hello
```
