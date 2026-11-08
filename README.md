# Tuck

Tuck is an **experimental build system** — a tool that, given a description of what
you want to build and how, figures out which steps need to run and in what order, then
runs them. Think `make`, but with stronger guarantees.

The project exists to experiment with three ideas:

## 1. A two-phase build model

Most build tools mix together *what to build* with *how to build it*. Tuck separates
them into two distinct phases:

1. **Loading phase** — Tuck reads your build files and constructs a complete *target
   graph*: all the things you want to produce and how they depend on each other. No
   compilation or file-writing happens here.
2. **Analysis phase** — Tuck runs rule logic against the target graph to produce an
   *action graph*: a precise, static description of every command that needs to run,
   every input it consumes, and every output it produces.

Only after both phases are complete does execution begin. This separation matters
because it lets you *inspect and validate* the full build plan before anything runs —
and it's what makes correctness guarantees (like incrementality and caching) tractable
to implement.

## 2. Hermetic builds

A build is **hermetic** if it only sees exactly the inputs you declared — no
accidental reads from the environment, no implicit dependencies on installed tools, no
surprises when the same build runs on a different machine. Hermetic builds are
reproducible: the same inputs always produce the same outputs.

Tuck enforces hermeticity through Tcl's *safe interpreter* boundary. Build files and
rule implementations run in locked-down child interpreters that have no access to the
filesystem, environment variables, or arbitrary commands. The only things they can do
are the narrow operations Tuck explicitly allows.

The commands a build runs are sandboxed too. Each action runs in its own directory
that contains only the files it declared as inputs, with an almost empty environment,
so a command that quietly reads an undeclared file fails instead of working by
accident. The sandbox is a plain directory, not a container: the toolchain (`cc`,
`ar`, …) comes from the host `PATH`, and keeping it pinned is up to you, as in Buck2.

## 3. A minimal, uniform DSL

Instead of inventing a grammar, Tuck reuses Tcl syntax for everything: rule
definitions, rule implementations, and build files. The constraint is the interpreter
boundary, not a grammar. This keeps the language surface small and familiar to anyone
who already knows Tcl, while still allowing rule authors to write expressive logic.

---

> **Status: Milestone 3 (execution phase).** Loading, analysis and single-threaded
> execution are implemented. See [`DESIGN.md`](DESIGN.md) for the
> full design and roadmap.

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
  name (its constructor command), a typed attr schema, and an impl proc.

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
            # invoked during analysis, with an implicit `ctx`
        }
    }
}
```

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

# Build a target: run its stale actions, print its output paths
tclsh tuck.tcl build //tools/hello:hello
```

Build outputs go to `tuck-out/<package>/__<target>__/` at the repo root. A second
`build` with nothing changed runs nothing. Set `TUCK_KEEP_SANDBOX=1` to keep a failed
action's sandbox directory for inspection.

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

New to the codebase (or to Tcl)? Start with [`docs/CODE-TOUR.md`](docs/CODE-TOUR.md),
a guided walkthrough that follows one command through every file and teaches the Tcl
concepts it relies on.
