# Tuck — Design Specification

> A hermetic, two-phase build system embedded in TCL, inspired by Buck2.
> Version: 0.1-draft

---

## 1. Principles

- **Two phases, two graphs.** Loading produces a target graph; analysis produces an
  action graph. Execution consumes the action graph. No phase may reach backwards.
- **Hermetic evaluation.** Every BUILD file and every rule implementation runs in an
  isolated child interpreter. Side effects on the root interpreter are only possible
  through explicit, narrow aliases.
- **Dynamic actions, static targets.** The target graph is fully resolved before
  analysis begins. The action graph may be extended at execution time via dynamic
  action thunks, but no new targets may be introduced after loading.
- **TCL is the language.** There is no separate DSL. Rule constructors, rule
  implementations, and build files are all TCL. The constraint is the interpreter
  boundary, not a grammar.
- **Labels are the identity.** Every target and every declared artifact is addressed
  by a canonical label string. There are no implicit dependencies.

---

## 2. Repository Layout

```
<root>/
  .tuck/                  # repository root marker
  TUCK                    # root BUILD file (optional)
  <package>/
    BUILD                 # one per package directory
    …source files…
  tuck.tcl                # the tuck binary / entry point
```

A **repository root** is the directory containing `.tuck/`.  
A **package** is any directory under the root that contains a `BUILD` file.  
A **target** lives in exactly one package.

---

## 3. Labels

Labels follow Buck2 conventions:

```
//path/to/package:target_name     # fully-qualified
:target_name                      # relative (within same package)
//path/to/package                 # shorthand for :package_name
```

Canonical form is always `//pkg:name`. Relative labels are resolved during the
loading phase against the package of the BUILD file being evaluated.

---

## 4. Phases

### 4.1 Loading Phase

**Input:** a set of BUILD files (determined by the query or target pattern).  
**Output:** the **target graph** — a DAG of target nodes.

Each BUILD file is evaluated in a short-lived **loader interpreter**. The loader
exposes exactly two commands:

| Command    | Description                                              |
|------------|----------------------------------------------------------|
| `targets`  | Evaluates its body in the **target interpreter**         |
| `rules`    | Evaluates its body in the **rules interpreter**          |

The **target interpreter** exposes only rule constructors (e.g. `genrule`,
`cc_binary`). Calling a constructor does not execute anything; it calls back into
the root via an alias to register a target node.

The **rules interpreter** exposes only `ctx::*` commands. Rule implementation procs
are defined here during loading and called during analysis.

No file I/O, no `exec`, no `package require` is available in either child interpreter
unless explicitly aliased.

### 4.2 Analysis Phase

**Input:** the target graph.  
**Output:** the **action graph** — a DAG of action nodes.

Targets are visited in reverse-dependency order (leaves first). For each target, its
rule implementation proc is invoked in the rules interpreter with a **context object**
(a dict). The impl calls `ctx` commands to declare artifacts and register actions.

Action nodes are immutable once registered. The action graph is append-only during
analysis.

### 4.3 Execution Phase

**Input:** the action graph, a set of requested output artifacts.  
**Output:** materialized artifacts on disk.

Execution is a worklist algorithm over the action graph:

1. Compute the transitive closure of actions needed for the requested outputs.
2. Maintain a ready queue: actions whose inputs are all materialized.
3. Dispatch ready actions (initially: single-threaded; parallel in a later milestone).
4. On completion, mark outputs as materialized and re-evaluate the ready queue.
5. For **dynamic actions**: when a dynamic action completes, invoke its thunk to
   produce new action nodes, insert them into the graph, and continue.

Content hashing is used to determine whether an action's outputs are already
up-to-date (milestone 2+). Initial implementation may use mtime.

---

## 5. Target Graph

### 5.1 Target Node

```tcl
dict create \
    label   //pkg:name         \
    rule    genrule            \
    attrs   { name … srcs … }  \
    package path/to/pkg        \
    deps    { //a:b //c:d }
```

`deps` is extracted from attrs during loading (all values that look like labels, plus
any attr declared with type `dep` or `deps` in the rule's attr schema).

### 5.2 Target Graph Invariants

- No duplicate labels.
- No cycles (checked after all BUILD files in a pass are loaded).
- All dep labels resolve to known targets (checked after loading, before analysis).

---

## 6. Action Graph

### 6.1 Artifact

An artifact is either a **source artifact** or a **declared artifact**.

```tcl
# source
dict create type source  path path/relative/to/repo/root

# declared
dict create type declared  target //pkg:name  relpath subdir/file.o
```

Artifact identity is its canonical string form:

```
source:path/to/file.c
declared://pkg:name:subdir/file.o
```

### 6.2 Action Node (static)

```tcl
dict create \
    id       <unique string>        \
    target   //pkg:name             \
    inputs   { artifact-id … }      \
    outputs  { artifact-id … }      \
    cmd      { sh -c "cc -o $OUT $SRCS" }  \
    env      { OUT … SRCS … }       \
    dynamic  false
```

### 6.3 Action Node (dynamic)

```tcl
dict create \
    id       <unique string>     \
    target   //pkg:name          \
    inputs   { artifact-id … }   \
    outputs  {}                  \
    dynamic  true                \
    thunk    proc-name-in-rules-interp
```

At execution time, after inputs are materialized, `thunk` is called with a fresh ctx.
It returns a list of new action nodes which are spliced into the action graph. The
dynamic action's declared outputs become the union of its thunk's registered outputs.

---

## 7. Rule System

### 7.1 Rule Definition

Rules are defined in the `rules { }` block of a BUILD file, or in a shared rule
library loaded via `tuck::load_rules`. A rule has:

- A **name** (the constructor command name, e.g. `genrule`)
- An **attr schema** (typed attribute declarations)
- An **impl proc** (called during analysis)

```tcl
rules {
    tuck::rule genrule {
        attrs {
            name   { type string   mandatory true  }
            srcs   { type sources  mandatory true  }
            out    { type string   mandatory true  }
            cmd    { type string   mandatory true  }
            deps   { type deps     mandatory false default {} }
        }
        impl {
            set srcs [ctx.attr    $ctx srcs]
            set out  [ctx.declare_output $ctx [ctx.attr $ctx out]]
            ctx.action $ctx \
                inputs  $srcs \
                outputs [list $out] \
                cmd     [ctx.attr $ctx cmd]
        }
    }
}
```

`tuck::rule` is aliased into the rules interpreter. It registers the rule in
`::tuck::graph::rules` and installs a constructor alias in the target interpreter.

The **impl is written inline** as a script body that takes an implicit `ctx`.
At registration it is compiled into a named proc `__tuck_impl_<name> {ctx} <body>`
in the rules interpreter, so analysis always invokes a real named proc (clean
stack traces) while the author writes the ergonomic inline form. Helper procs may
be defined separately in the `rules { }` block and called from the body; a body of
`{ my_helper $ctx }` recovers the old named-proc style when that is preferred.

### 7.2 Attr Types

| Type      | TCL representation         | Notes                            |
|-----------|----------------------------|----------------------------------|
| `string`  | bare string                |                                  |
| `int`     | integer                    |                                  |
| `bool`    | 0 / 1                      |                                  |
| `list`    | TCL list                   |                                  |
| `sources` | list of strings            | resolved relative to package dir |
| `dep`     | label string               | added to target's dep set        |
| `deps`    | list of label strings      | added to target's dep set        |
| `output`  | string                     | declared artifact relpath        |

### 7.3 Ctx Commands

These are the only commands available to a rule impl:

| Command                              | Description                                         |
|--------------------------------------|-----------------------------------------------------|
| `ctx.attr $ctx $key`                 | Retrieve a validated attr value                     |
| `ctx.label $ctx`                     | The target's own label                              |
| `ctx.package $ctx`                   | The target's package path                           |
| `ctx.declare_output $ctx $relpath`   | Declare a new output artifact; returns artifact id  |
| `ctx.action $ctx …`                  | Register a static action node                       |
| `ctx.dynamic_action $ctx …`          | Register a dynamic action node with a thunk proc    |
| `ctx.dep_outputs $ctx $label`        | Get declared outputs of a dependency target         |

---

## 8. Namespace Layout

```
::tuck::
  config::
    root          # repo root path
    output_base   # where declared artifacts are materialized

  graph::
    targets       # dict: label       → target node
    rules         # dict: rule-name   → {schema impl-proc}
    actions       # dict: action-id   → action node
    artifacts     # dict: artifact-id → artifact

  interp::
    rules         # the shared rules child interpreter
    target        # the shared target child interpreter

# CORRECTION (M1): The singular, shared `interp::rules` / `interp::target`
# above are only sound if their contents are established *deterministically*,
# before lazy/transitive package loading begins. Under lazy loading the order
# in which package BUILD files are read is undefined, so rules must NOT be
# accumulated "as packages load" — a rule defined in one package cannot be
# relied upon by another, since load order is unstable.
#
# Resolution adopted for M1: rules are repo-global and defined ONLY in the
# root `TUCK` file, which is loaded first, before any package. Its `rules {}`
# block populates the shared rules interp and installs constructors in the
# shared target interp. Package `BUILD` files contain only `targets {}`.
# Per-package `rules {}` blocks (as sketched in §7.1 / §9) are deferred; when
# reintroduced they must use freshly-seeded per-package interps so that
# package-local rules cannot leak and load order remains irrelevant.

  phase::
    load          # proc: path → (populates graph::targets, graph::rules)
    analyse       # proc: labels → (populates graph::actions)
    execute       # proc: artifact-ids → (materializes outputs)

  ctx::
    attr
    label
    package
    declare_output
    action
    dynamic_action
    dep_outputs

  util::
    label_parse   # string → {root pkg name}
    label_canon   # pkg name → //pkg:name
    label_deps    # attrs schema → list of dep labels from attr values
    topo_sort     # graph dict → sorted label list
    hash_file     # path → sha256 hex
```

---

## 9. BUILD File Anatomy

```tcl
# BUILD file for package  //tools/hello

rules {
    # Rule definitions (optional — may be inherited from root)
    tuck::rule cc_binary {
        attrs {
            name  { type string  mandatory true }
            srcs  { type sources mandatory true }
            deps  { type deps    mandatory false default {} }
        }
        impl {
            set srcs [ctx.attr $ctx srcs]
            set out  [ctx.declare_output $ctx [ctx.attr $ctx name]]
            ctx.action $ctx \
                inputs  $srcs \
                outputs [list $out] \
                cmd     [list cc -o [ctx.attr $ctx name] {*}$srcs]
        }
    }
}

targets {
    cc_binary(
        name = "hello",
        srcs = ["main.c"],
    )
}
```

---

## 10. CLI (sketch)

```
tuck build //tools/hello:hello
tuck build //...                   # all targets
tuck query deps //tools/hello:hello
tuck query rdeps //lib:util
```

---

## 11. Milestones

| # | Scope |
|---|-------|
| M1 | Repo root detection, BUILD loading, target graph, topo-sort, label resolution |
| M2 | Analysis phase, static action graph, `genrule` built-in rule |
| M3 | Execution phase, single-threaded, mtime staleness check, pure-Tcl directory sandbox (see `docs/superpowers/specs/2026-11-08-tuck-m3-design.md`) |
| M4 | Dynamic actions and thunks |
| M5 | Content-hash caching, output base isolation |
| M6 | Parallel execution (coroutine-based or thread-based) |
| M7 | `tuck query` subcommands |
| M8 | Rule libraries (`tuck::load_rules`), root-level shared rules |
