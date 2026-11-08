# Example: building a C project with Tuck

A small, self-contained Tuck repository that models a real C build: a static
library and an executable that links against it. It shows the whole pipeline on
a project more meaningful than the unit-test fixtures: the **target graph**, the
**action graph**, and the build itself, with each action run in a sandbox.

You need Tcl 9+ and a C compiler (`cc`) on your `PATH`. Tuck does not provide a
toolchain: whatever `cc` and `ar` the host has are the ones the build uses.

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

- **`cc_library`** compiles each C source to an object file and bundles the
  objects into a static archive (`ar rcs`). It also copies its headers to
  `include/`. The archive and the headers are its public outputs, so a
  dependent that calls `ctx dep_outputs` sees exactly those.
- **`cc_binary`** compiles its own sources against its deps' published headers,
  then links the objects with the deps' archives into an executable.

Each rule's `impl` body emits actions during analysis using the `ctx` command
(`ctx attr`, `ctx declare_output`, `ctx action`, `ctx dep_outputs`, `ctx path`).
Every file an action touches is an artifact, and commands name files by
`ctx path`. Object files are declared with `-private`: they are real artifacts,
but dependents do not see them. Because the rules interpreter is sandboxed
(`file` is unavailable), the small path helpers at the top of `TUCK` use plain
string operations.

## Inspecting the build

Run these from inside `example/`.

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
every action, leaves first:

```console
$ tclsh ../tuck.tcl analyze //app:hello
//lib/greet:greet#0
  inputs:  source:lib/greet/greet.c source:lib/greet/greet.h
  outputs: declared://lib/greet:greet:build/greet.o
  cmd:     cc -Ilib/greet -c lib/greet/greet.c -o tuck-out/lib/greet/__greet__/build/greet.o
//lib/greet:greet#1
  inputs:  source:lib/greet/greet.h
  outputs: declared://lib/greet:greet:include/greet.h
  cmd:     cp lib/greet/greet.h tuck-out/lib/greet/__greet__/include/greet.h
//lib/greet:greet#2
  inputs:  declared://lib/greet:greet:build/greet.o
  outputs: declared://lib/greet:greet:build/libgreet.a
  cmd:     ar rcs tuck-out/lib/greet/__greet__/build/libgreet.a tuck-out/lib/greet/__greet__/build/greet.o
//app:hello#0
  inputs:  source:app/main.c declared://lib/greet:greet:include/greet.h
  outputs: declared://app:hello:build/main.o
  cmd:     cc -Ituck-out/lib/greet/__greet__/include -c app/main.c -o tuck-out/app/__hello__/build/main.o
//app:hello#1
  inputs:  declared://app:hello:build/main.o declared://lib/greet:greet:build/libgreet.a
  outputs: declared://app:hello:build/hello
  cmd:     cc tuck-out/app/__hello__/build/main.o tuck-out/lib/greet/__greet__/build/libgreet.a -o tuck-out/app/__hello__/build/hello
```

Reading the graph:

- Each action is `<label>#<n>`. Inputs and outputs are *artifacts*: `source:…`
  for files in the repo, `declared:<label>:<relpath>` for files a rule declared.
- Declared artifacts live under `tuck-out/<package>/__<target>__/`, so two
  targets can both produce `build/main.o` without clashing.
- `//lib/greet:greet` is analysed before `//app:hello`, so `ctx dep_outputs`
  always sees a dependency's outputs.

### Actions for a single target

`query actions` restricts the dump to one target (no dependencies):

```console
$ tclsh ../tuck.tcl query actions //app:hello
//app:hello#0
  inputs:  source:app/main.c declared://lib/greet:greet:include/greet.h
  outputs: declared://app:hello:build/main.o
  cmd:     cc -Ituck-out/lib/greet/__greet__/include -c app/main.c -o tuck-out/app/__hello__/build/main.o
//app:hello#1
  inputs:  declared://app:hello:build/main.o declared://lib/greet:greet:build/libgreet.a
  outputs: declared://app:hello:build/hello
  cmd:     cc tuck-out/app/__hello__/build/main.o tuck-out/lib/greet/__greet__/build/libgreet.a -o tuck-out/app/__hello__/build/hello
```

## Building

`build` analyses the target, runs every action needed for its outputs, and
prints where those outputs are:

```console
$ tclsh ../tuck.tcl build //app:hello
run  //lib/greet:greet#1
run  //app:hello#0
run  //lib/greet:greet#0
run  //lib/greet:greet#2
run  //app:hello#1
tuck-out/app/__hello__/build/hello
$ ./tuck-out/app/__hello__/build/hello Tuck
Hello, Tuck!
```

Actions run in an order where every input exists before it is read (here, the
DFS order from the requested output, not the order `analyze` prints).

Build again and nothing runs. Tuck records each action's command and the
`mtime` and size of its inputs in `tuck-out/.db`, and an action re-runs only
when one of those changes or an output is missing:

```console
$ tclsh ../tuck.tcl build //app:hello
skip //lib/greet:greet#1
skip //app:hello#0
skip //lib/greet:greet#0
skip //lib/greet:greet#2
skip //app:hello#1
tuck-out/app/__hello__/build/hello
```

### The sandbox

Each action runs in its own directory under `tuck-out/sandbox/`, which contains
only that action's declared inputs, with an almost empty environment (`PATH`
from the host, a private `HOME` and `TMPDIR`, `LANG=C`, `TZ=UTC`). Its declared
outputs are then moved into `tuck-out/`.

An earlier version of this example compiled `main.c` with `-Ilib/greet`, but
never declared `greet.h` as an input of that compile. Run in the repo, it worked
by accident. Run in the sandbox, `greet.h` does not exist, and the compile
fails. That is why `cc_library` now publishes its headers and `cc_binary`
compiles against them.

The sandbox is a directory, not a container: an action can still read absolute
paths such as `/usr/include`, and use the network. Set `TUCK_KEEP_SANDBOX=1` to
keep a failed action's sandbox for inspection.
