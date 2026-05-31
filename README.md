# Tuck

A hermetic, two-phase build system embedded in TCL, inspired by [Buck2](https://buck2.build/).

Tuck evaluates `BUILD` files in isolated child interpreters to produce a **target
graph** (loading phase), which later analysis turns into an **action graph**, which
execution materializes. There is no separate DSL — rule constructors, rule
implementations, and build files are all TCL; the constraint is the interpreter
boundary, not a grammar.

> **Status: Milestone 2 (analysis phase).** On top of M1's loading phase, Tuck now
> runs rule impls via `ctx.*` commands to build a static action graph (artifacts +
> action nodes). Execution is a future milestone. See [`DESIGN.md`](DESIGN.md) for
> the full design and milestone roadmap.

## Requirements

- Tcl 9.0+ (`tclsh`)

No external packages — Tuck uses only the Tcl core and the built-in `tcltest`.

## Concepts

- **Repo root** — the directory containing a `.tuck/` marker.
- **Package** — any directory under the root containing a `BUILD` file; its identity
  is its path relative to the root (e.g. `tools/hello`).
- **Label** — the canonical identity of a target, `//pkg:name`. Relative `:name`
  resolves within the current package; `//pkg` is shorthand for `//pkg:<basename>`.
- **Rules** — defined once in the root `TUCK` file and shared repo-wide. A rule has a
  name (its constructor command), a typed attr schema, and an impl proc (used in a
  later milestone).

## Repository layout

```
<root>/
  .tuck/          # repo root marker
  TUCK            # root build file: defines repo-global rules
  <package>/
    BUILD         # one per package: declares targets
    …sources…
```

## Build file anatomy

Rules live in the root `TUCK`:

```tcl
rules {
    tuck::rule genrule {
        attrs {
            name { type string  mandatory true }
            srcs { type sources mandatory true }
            out  { type string  mandatory true }
            deps { type deps    mandatory false default {} }
        }
        impl {
            # invoked during the analysis phase (a later milestone),
            # with an implicit `ctx`
        }
    }
}
```

The `impl` is written inline as a script body taking an implicit `ctx`; Tuck
compiles it into a named proc behind the scenes. Helper procs can be defined
elsewhere in the `rules` block and called from the body.

Targets are declared in each package's `BUILD` using dict-style constructors:

```tcl
targets {
    genrule {
        name hello
        srcs {main.c util.c}
        out  hello
        deps {//lib:util}
    }
}
```

## Usage

Run from anywhere inside a Tuck repo (the root is found by walking up to `.tuck/`):

```sh
# List targets matching a pattern
tclsh tuck.tcl targets //tools/hello:hello   # exact target
tclsh tuck.tcl targets //tools/hello         # package default target
tclsh tuck.tcl targets //tools/hello:...     # all targets in a package
tclsh tuck.tcl targets //...                 # all targets in the repo

# Print a target's transitive dependencies, leaves first
tclsh tuck.tcl query deps //tools/hello:hello

# Analyse a target's closure and print the action graph
tclsh tuck.tcl analyze //tools/hello:hello

# Print just one target's actions
tclsh tuck.tcl query actions //tools/hello:hello
```

`targets` and `query deps` load only the packages they need: loading follows
dependency edges transitively and stops when the graph closes (`//...` is the one
exception — it scans the tree).

## Development

Tuck is built test-first with `tcltest`. Run the full suite:

```sh
tclsh tests/all.tcl
```

Run a single suite:

```sh
tclsh tests/label.test
```

Source files live in `lib/` (one namespace per concern); `tuck.tcl` only wires the
CLI to the phases. Design and implementation notes are under `docs/superpowers/`.
