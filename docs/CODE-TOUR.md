# Tuck — a code tour for people who don't know TCL

Tuck is written in TCL, a language most developers today have never used. The good
news: the codebase is small (~650 lines) and every file has one job. This guide walks
through it by **following a single command** —

```sh
tclsh tuck.tcl analyze //tools/hello:hello
```

— from the moment you press Enter to the moment Tuck prints a build plan. That one path
touches every source file in roughly the order it runs, so by the end you will have
seen the whole system. Along the way we explain the TCL you need, and only the TCL you
need.

If you want the *design rationale* (why two phases, why hermetic), read
[`DESIGN.md`](../DESIGN.md). This guide is about reading the *code*.

---

## 1. The mental model

Two ideas explain almost everything in Tuck.

**Two phases, two graphs.** A build runs in stages that never reach backwards:

1. **Loading.** Read `BUILD` files and produce a *target graph* — the set of things
   you could build (`//tools/hello:hello`) and which targets depend on which.
2. **Analysis.** Walk that graph and produce an *action graph* — the concrete
   artifacts (files) and actions (commands) needed to build a target. This is what
   `analyze` prints.
3. **Execution.** Actually run the actions. (Not implemented yet — a future milestone.)

**Hermeticity by isolation.** A build system must be reproducible, so `BUILD` files and
rule code are *not allowed to do whatever they want* — no reading random files, no
shelling out. Tuck enforces this by running that untrusted code inside **sandboxed
child interpreters** that physically cannot touch the filesystem. The only way out of
the sandbox is a short list of explicit bridges (`alias`es). We explain interpreters in
§2 — they are the single most important TCL concept in this codebase.

A third idea: **TCL is the language.** There is no separate build-file grammar. `BUILD`
files, rule definitions, and rule implementations are all just TCL evaluated in those
sandboxes. The safety comes from the sandbox boundary, not from a restricted syntax.

---

## 2. The TCL you need, scoped to Tuck

Read this once; the walkthrough (§3) refers back to it instead of re-explaining.

### Everything is a command; `{ ... }` is just text

TCL has almost no syntax. A script is a sequence of commands, each `command arg arg
...`. Even `if`, `proc`, and `namespace` are ordinary commands that happen to take code
as arguments.

Crucially, **a brace block `{ ... }` is just a string** — an unevaluated chunk of text.
It only becomes code if some command decides to evaluate it. That is why Tuck can write

```tcl
targets {
    genrule { name hello srcs {main.c} out hello }
}
```

and treat the inner block sometimes as *code* (a list of constructor calls) and
sometimes as pure *data* (a dict of attributes). The braces don't decide; the command
that receives them does. The command that evaluates a string as code is `eval`.

*You'll see this in:* `loader.tcl` (`$loader eval $src`), everywhere `targets`/`rules`
blocks appear.

### Procedures and `upvar`

`proc name {args} {body}` defines a procedure. Arguments are passed by value. When a
proc needs to *modify a caller's variable* (e.g. an accumulator), the caller passes the
variable's **name** and the proc binds to it with `upvar`:

```tcl
proc add_one {varName} {
    upvar 1 $varName v   ;# v is now an alias for the caller's variable
    incr v
}
```

*You'll see this in:* `graph.tcl`, where the topo-sort passes its `state` and `result`
accumulators by name into the recursive helper.

### Dicts are the universal data structure

A **dict** is an ordered key/value map (under the hood, just a list of alternating keys
and values). Tuck represents *everything* structured as a dict: a parsed label is
`{pkg tools/hello name hello}`; a target node is a dict with keys `label rule attrs
package deps`; the rule registry, the artifact store, and the action store are dicts of
dicts. Key operations you'll see:

- `dict create k1 v1 k2 v2` — build one.
- `dict get $d key` (or `dict get $d k1 k2` to reach into nested dicts) — read.
- `dict set ::var key val` — write (here, into a namespaced global).
- `dict exists $d key` — test.
- `dict for {k v} $d { ... }` — iterate.

*You'll see this in:* every file.

### Namespaces

A **namespace** is a container for variables and procs, written with `::` separators,
like a path: `::tuck::graph::targets` is the variable `targets` in namespace
`::tuck::graph`. Tuck uses **one namespace per concern** (see the table in
[`CLAUDE.md`](../CLAUDE.md)). Two things to know:

- You must **create a namespace before** you can put a qualified variable in it:
  `namespace eval ::tuck::graph {}` first, then you can `set ::tuck::graph::targets`.
  That's why files open with a `namespace eval` line.
- `variable name value` *inside* a `namespace eval` block declares a namespace
  variable. Tuck's mutable global state (the target graph, the action graph, the two
  shared interpreters) lives in such variables.

*You'll see this in:* the top of every file.

### Child interpreters, `-safe`, and `alias` — the heart of Tuck

This is the concept that makes Tuck hermetic, so it's worth slowing down.

A running TCL program is an **interpreter**: a bag of commands plus variable/namespace
state. A program can create *more* interpreters as children, each with its own
independent set of commands and state:

```tcl
set child [interp create]          ;# a full-powered child
$child eval { puts hello }         ;# run code inside it
```

Add `-safe` and you get a **safe interpreter** — a child with all the dangerous
commands *removed*: no `open`, no `exec`, no `file`, no `package`, no `socket`. Code
running inside a safe interp **literally cannot read a file or run a program.** That is
the sandbox.

```tcl
set sandbox [interp create -safe]
$sandbox eval { open /etc/passwd }   ;# error: invalid command name "open"
```

So how does sandboxed code ever do anything useful? Through an **alias**: a command
name inside the child that is wired to a proc in the *parent*. When the child calls it,
the parent's proc runs (with the parent's full privileges) and returns the result:

```tcl
$sandbox alias readfile ::myapp::safe_read   ;# expose ONE narrow bridge
# now `readfile foo` inside $sandbox calls ::myapp::safe_read in the parent
```

This is the entire security model. Untrusted `BUILD`/rule code runs in safe interps; the
**root interpreter** (the trusted one that started everything and is the only code
allowed to read from disk) exposes a handful of narrow aliases as the only escape
hatches. Tuck uses exactly three child interpreters and a small set of aliases — that's
§4.1.

You can also **curry** an alias: extra arguments after the target proc are silently
prepended to every call. `$child alias ctx ::dispatch $node` means "every `ctx ...`
call in the child actually runs `::dispatch $node ...`". Tuck uses this trick to inject
the *current target* into rule code without the rule author passing it — that's §4.2.

*You'll see this in:* `loader.tcl` (creates the interps and aliases), `analyse.tcl` and
`ctx.tcl` (the currying trick).

---

## 3. The walkthrough — following `analyze //tools/hello:hello`

Now we trace the command, file by file, in the order it executes.

### `tuck.tcl` — the entry point

This is the only file the shell runs directly, and the only place the CLI is wired to
the phases. The top sources every `lib/` file into the root interpreter:

```tcl
foreach m {config label rules target graph action ctx analyse loader} {
    source [file join $::tuck::_libdir $m.tcl]
}
```

`::tuck::main` is the dispatcher. For *every* command it first establishes the world,
then switches on the subcommand:

```tcl
proc ::tuck::main {argv} {
    ::tuck::reset                       ;# clear all state
    ::tuck::config::init [pwd]          ;# find the repo root
    ::tuck::phase::setup                ;# create the shared interpreters
    ::tuck::phase::load_root_rules      ;# load repo-global rules first
    set cmd [lindex $argv 0]
    switch -- $cmd {
        targets { ::tuck::cmd::targets [lindex $argv 1] }
        analyze { ::tuck::cmd::analyze [lindex $argv 1] }
        query   { ... }
        default { error "tuck: unknown command: $cmd" }
    }
}
```

For our command, `analyze` calls `::tuck::cmd::analyze`, which runs the analysis phase
and prints every action in the resulting action graph. The bottom of the file is the
top-level error trap: any `error` raised anywhere bubbles up here, prints to stderr, and
exits non-zero. (Note the `tuck:` prefix convention on error messages — every
intentional failure in the codebase uses it.)

The rest of `tuck.tcl` is the other CLI subcommands (`targets`, `query deps`, `query
actions`) and their print helpers. They are pure orchestration; all real logic lives in
`lib/`.

### `config.tcl` — finding the repo root

A Tuck repository is marked by a `.tuck/` directory, the way a Git repo is marked by
`.git/`. `find_root` walks **up** the directory tree from the current directory until it
finds one:

```tcl
proc ::tuck::config::find_root {start} {
    set dir [file normalize $start]
    while 1 {
        if {[file isdirectory [file join $dir .tuck]]} { return $dir }
        set parent [file dirname $dir]
        if {$parent eq $dir} { error "tuck: no .tuck/ found ..." }  ;# hit / 
        set dir $parent
    }
}
```

`init` caches the result in the namespace variable `::tuck::config::root`, which the
loader later joins with package paths to locate `BUILD` files. This runs in the **root**
interpreter — it's allowed to use `file`, which the sandboxes are not.

### `loader.tcl` — the three interpreters (the heart of hermeticity)

This file builds and manages the sandbox machinery from §2. `setup` creates the two
long-lived child interpreters and wires their aliases:

```tcl
proc ::tuck::phase::setup {} {
    set ::tuck::interp::target [interp create -safe]
    set ::tuck::interp::rules  [interp create -safe]
    $::tuck::interp::rules alias tuck::rule ::tuck::register_rule
    ::tuck::ctx::install $::tuck::interp::rules
}
```

Tuck uses **three** sandboxed interpreters, each with a single responsibility (this is
the model spelled out in §4.1):

- **loader** — created *fresh per `BUILD`/`TUCK` file and deleted after*. It exposes
  only `targets` and `rules`, the two top-level block commands.
- **target** — shared and persistent. Holds the rule *constructors* (one command per
  rule, e.g. `genrule`). A `targets { ... }` block is evaluated here.
- **rules** — shared and persistent. Holds `tuck::rule` and the compiled rule impls. A
  `rules { ... }` block is evaluated here.

`load_file` shows the per-file lifecycle: read the file (in the root interp, which can),
spin up a throwaway loader sandbox, alias its two commands back to the root, evaluate
the file's text, and always delete the sandbox afterward:

```tcl
proc ::tuck::phase::load_file {path pkg} {
    set ::tuck::_current_pkg $pkg
    set src [::tuck::phase::_slurp $path]          ;# root reads the file
    set loader [interp create -safe]
    $loader alias targets ::tuck::phase::_eval_targets
    $loader alias rules   ::tuck::phase::_eval_rules
    try { $loader eval $src } finally { interp delete $loader }
}
```

Those two aliases just forward the block into the right persistent interp — `targets
{body}` runs `body` in the **target** interp, `rules {body}` runs it in the **rules**
interp. Note who reads disk and who doesn't: `_slurp` (root) opens the file; the
sandbox only ever sees the already-read text.

The bottom of the file is **lazy, transitive loading**. `load_closure` starts from the
packages you asked for and follows dependency edges to other packages until no new ones
appear — it loads exactly what's needed and no more:

```tcl
proc ::tuck::phase::load_closure {seed_pkgs} {
    set loaded {}; set pending $seed_pkgs
    while {[llength $pending]} {
        set pkg [lindex $pending 0]; set pending [lrange $pending 1 end]
        if {[dict exists $loaded $pkg]} continue
        dict set loaded $pkg 1
        ::tuck::phase::load_package $pkg
        # ...enqueue the packages of every dep we just discovered...
    }
}
```

`reset` (top of the file) tears all of this down — clears the graph dicts and deletes
the shared interps — so each CLI run and each test starts from a clean world.

### `label.tcl` — target identity

Every target is named by a **label** in canonical form `//pkg:name` (Buck2 convention).
Labels can be written three ways, and `label_parse` normalizes them into a
`{pkg ... name ...}` dict:

- `//tools/hello:hello` — fully qualified.
- `//tools/hello` — shorthand; name defaults to the last path segment (`hello`).
- `:hello` — relative; `pkg` defaults to the package currently being loaded.

`canon` is the convenience wrapper: parse against a package, then re-emit canonical
`//pkg:name`. This namespace is `::tuck::util` (label handling is a utility, not a
phase).

### `rules.tcl` — defining rules (loading phase)

A **rule** is a target *type* (like `genrule`). Rules are defined once, in the repo's
root `TUCK` file, so they're identical everywhere. A rule has a name, a typed **attr
schema**, and an **impl** (the analysis-time body).

`register_rule` runs (via the `tuck::rule` alias) whenever the root `TUCK` defines a
rule. It does three things:

```tcl
proc ::tuck::register_rule {name body} {
    set schema [dict get $body attrs]
    set impl ""
    if {[dict exists $body impl]} {
        set impl __tuck_impl_$name
        $::tuck::interp::rules eval [list proc $impl {} [dict get $body impl]]
    }
    dict set ::tuck::graph::rules $name [dict create schema $schema impl $impl]
    ::tuck::_install_ctor $name
}
```

1. Stores the attr **schema**.
2. **Compiles the inline `impl` block into a named, zero-argument proc**
   (`__tuck_impl_<name>`) inside the rules interp. The author writes `impl { ... }` as
   ergonomic inline text; Tuck turns it into a real proc so analysis can call it by name
   (and so stack traces are sane). How that proc gets access to the current target is
   the currying trick — see §4.2.
3. Calls `_install_ctor` (in `loader.tcl`), which adds a constructor command of the
   rule's name into the **target** interp, so `BUILD` files can write `genrule { ... }`.

`validate_attrs` and `check_type` enforce the schema when a target is declared: missing
mandatory attrs, unknown attrs, and bad types all raise `tuck:`-prefixed errors;
defaults are filled in. Type checking is minimal for now (`int`/`bool` are checked;
`string`/`list`/`sources`/`dep`/`deps`/`output` are accepted as-is).

### `target.tcl` — declaring targets (loading phase)

When a `BUILD` file calls a rule constructor like `genrule { ... }`, the target interp's
alias routes it to `register_target`:

```tcl
proc ::tuck::register_target {rule attrs} {
    variable _current_pkg
    set schema [dict get $::tuck::graph::rules $rule schema]
    set valid  [::tuck::validate_attrs $rule $schema $attrs]   ;# schema check
    set label  [::tuck::util::label_canon $_current_pkg [dict get $valid name]]
    if {[dict exists $::tuck::graph::targets $label]} {
        error "tuck: duplicate target label: $label"
    }
    set deps [::tuck::extract_deps $schema $valid $_current_pkg]
    dict set ::tuck::graph::targets $label [dict create \
        label $label rule $rule attrs $valid package $_current_pkg deps $deps]
}
```

It validates the attrs, builds the canonical label, rejects duplicates, and stores a
**target node** (a dict) in `::tuck::graph::targets`. `extract_deps` pulls dependency
labels out of any attr whose schema type is `dep` or `deps` and canonicalizes them — so
the graph's edges come straight from the typed schema, not from guesswork.

At the end of loading, `::tuck::graph::targets` *is* the target graph.

### `graph.tcl` — validation and ordering

Two pure graph operations over `::tuck::graph::targets`:

`validate` checks that every dependency names a target that actually exists — catching
dangling deps before analysis.

`topo_sort` produces a **leaves-first** ordering via post-order depth-first search, and
**detects cycles** along the way. Leaves-first matters: analysis must process a
dependency *before* anything that depends on it (so the dependency's outputs already
exist when needed). This is the file that uses `upvar` (see §2) to thread its `state`
and `result` accumulators through the recursion:

```tcl
proc ::tuck::graph::_visit {label stateVar resultVar path} {
    upvar 1 $stateVar state $resultVar result   ;# bind to caller's accumulators
    if {[dict exists $state $label]} {
        if {[dict get $state $label] eq "visiting"} {
            error "tuck: dependency cycle: [join [concat $path $label] { -> }]"
        }
        return
    }
    dict set state $label visiting
    foreach dep [dict get $::tuck::graph::targets $label deps] {
        ::tuck::graph::_visit $dep state result [concat $path $label]
    }
    dict set state $label done
    lappend result $label                        ;# post-order: append after children
}
```

The `visiting`/`done` marking is the classic three-color DFS: re-entering a node still
marked `visiting` means we've looped back on ourselves — a cycle.

### `analyse.tcl` + `ctx.tcl` + `action.tcl` — the analysis phase

This is where our `analyze` command does its real work. `analyse` ties everything
together:

```tcl
proc ::tuck::phase::analyse {labels} {
    # ...canonicalize labels, find their packages...
    ::tuck::phase::load_closure $pkgs    ;# loading phase: build the target graph
    ::tuck::graph::validate              ;# no dangling deps
    # ...error if a requested target doesn't exist...
    foreach label [::tuck::graph::topo_sort $canon] {     ;# leaves first
        set node [dict get $::tuck::graph::targets $label]
        set impl [dict get $::tuck::graph::rules [dict get $node rule] impl]
        $::tuck::interp::rules alias ctx ::tuck::ctx::dispatch $node   ;# (!) §4.2
        $::tuck::interp::rules eval [list $impl]                       ;# run the impl
    }
}
```

For each target, in leaves-first order, it **curries the target node into the `ctx`
alias** and then invokes that target's compiled impl proc. The impl runs inside the
rules sandbox and talks to the rest of the system *only* through `ctx`.

`ctx.tcl` defines that `ctx` surface — the one bridge rule code has to the build graph.
`dispatch` receives the curried `node` plus whatever subcommand the impl called and
forwards to the matching accessor:

```tcl
proc ::tuck::ctx::dispatch {node subcmd args} {
    switch -- $subcmd {
        attr - label - package - declare_output - action - dep_outputs {
            return [::tuck::ctx::$subcmd $node {*}$args]
        }
        default { error "tuck: ctx: unknown subcommand '$subcmd'" }
    }
}
```

So a rule impl writes `ctx attr srcs`, `ctx declare_output hello`, `ctx action inputs
... outputs ... cmd ...`, and each call lands in the corresponding `::tuck::ctx::*` proc
*with the current target already supplied*. The author never passes the target around.
The accessors:

- `ctx attr key` — read an attribute, **type-resolved**: a `sources` attr comes back as
  registered source-artifact ids, `dep`/`deps` come back canonicalized.
- `ctx label` / `ctx package` — identity of the current target.
- `ctx declare_output relpath` — register a file this target will produce; records it in
  `target_outputs` and returns its artifact id.
- `ctx dep_outputs label` — the declared outputs of an *already-analysed* dependency.
  (Leaves-first ordering is what guarantees they exist.)
- `ctx action ...` — register an action (a command with inputs, outputs, env).

Before any target is bound, `ctx` is aliased to `_unbound`, which errors — so calling
`ctx` outside analysis fails loudly instead of silently misbehaving.

`action.tcl` is the storage layer the accessors write into: four namespace dicts —
`artifacts`, `actions`, `target_outputs`, and a per-target `_action_counter`. It mints
stable ids (`source:<path>`, `declared:<label>:<path>`, and per-target sequential action
ids `<label>#<n>`) and stores each artifact/action as a dict. Action `cmd`s are stored
**verbatim** — no path substitution happens until execution (a later milestone).

When `analyse` finishes, `::tuck::graph::actions` and `::tuck::graph::artifacts`
together are the **action graph**, and `tuck.tcl` prints it. Done.

---

## 4. The two tricky mechanisms

Everything above is straightforward once you accept §2. Two mechanisms deserve a second
look because they're the cleverest — and least obvious — parts of the design.

### 4.1 The three-interpreter model

There are **four** interpreters in play, and knowing which code runs where is the key to
reading the codebase:

```
            ┌─────────────────────────────────────────────┐
            │ ROOT interp (trusted)                         │
            │  • the only code that reads disk (open/file)  │
            │  • holds the target graph + action graph      │
            │  • all ::tuck::* procs live here              │
            └───────┬───────────────┬───────────────┬──────┘
        alias       │     alias      │     alias      │  alias
   targets/rules    │  (rule ctors)  │  tuck::rule    │  ctx
                    ▼                ▼   + ctx         ▼
            ┌───────────────┐ ┌────────────┐ ┌────────────────┐
            │ LOADER (safe) │ │ TARGET     │ │ RULES (safe)   │
            │ fresh per     │ │ (safe,     │ │ persistent     │
            │ file, then    │ │ persistent)│ │ holds compiled │
            │ deleted       │ │ rule ctors │ │ impls + ctx    │
            │ has: targets, │ │ runs       │ │ runs           │
            │      rules    │ │ targets{}  │ │ rules{} & impls│
            └───────────────┘ └────────────┘ └────────────────┘
```

- The **loader** sandbox sees a `BUILD`/`TUCK` file's text and only knows two commands,
  `targets` and `rules`. Each just forwards its block to the right persistent interp.
  It's recreated per file and deleted after, so no file can leave state behind for the
  next.
- The **target** sandbox accumulates rule constructor commands (`genrule`, …) as rules
  are registered, and is where every `targets { ... }` block runs. Constructor calls
  alias back to `register_target` in the root.
- The **rules** sandbox holds `tuck::rule`, the compiled `__tuck_impl_*` procs, and the
  `ctx` command. Both `rules { ... }` blocks and rule impls run here.
- The **root** interp is the trusted orchestrator: it reads files, holds all the graph
  state, and exposes the narrow aliases that are the *only* way the sandboxes affect the
  outside world.

This is why hermeticity holds: untrusted code never runs anywhere except a `-safe`
interp, and the aliases are a closed, auditable list.

### 4.2 Inline `impl` → compiled proc → curried `ctx`

A rule author writes an implementation as an inline block that uses an implicit `ctx`:

```tcl
tuck::rule genrule {
    attrs { ... }
    impl {
        set out [ctx declare_output [ctx attr out]]
        ctx action inputs [ctx attr srcs] outputs [list $out] cmd { ... }
    }
}
```

Notice there is no `ctx` parameter and no `proc` — yet `ctx` works and "knows" which
target it's operating on. Three steps make that happen:

1. **Compile (at registration, `rules.tcl`).** `register_rule` takes the `impl` block's
   text and defines it as a *zero-argument* proc in the rules interp:
   `proc __tuck_impl_genrule {} { ...the block... }`. The block is data until this
   moment; now it's a callable proc with a real name (good for stack traces).

2. **Curry (at analysis, `analyse.tcl`).** Just before invoking a target's impl,
   analysis rebinds the `ctx` alias *for that target*:

   ```tcl
   $::tuck::interp::rules alias ctx ::tuck::ctx::dispatch $node
   ```

   Because of alias currying (§2), every `ctx ...` call inside the impl now actually
   runs `::tuck::ctx::dispatch $node ...` — the current target node is silently
   prepended to every call. The impl doesn't pass it; analysis injected it.

3. **Dispatch (at call time, `ctx.tcl`).** `dispatch $node attr out` forwards to
   `::tuck::ctx::attr $node out`, which reads from `$node`. Every accessor receives the
   target as its first argument without the author ever writing it.

Why is a single shared `ctx` binding safe, given it's mutated per target? Because
analysis is strictly sequential and impls never nest — exactly one target is "current"
at any instant. The binding is set, the impl runs to completion, then it's reset for the
next target. (Helper procs defined in a `rules { ... }` block work the same way: they
call `ctx ...` directly, since the alias is live in the rules interp throughout that
target's analysis.)

That pairing — *compile the convenient inline form into a real proc, then feed it
context through a curried alias* — is the single most distinctive trick in Tuck. Once it
clicks, the rest of the analysis phase is just bookkeeping.

---

## Where to go next

- [`DESIGN.md`](../DESIGN.md) — the design rationale and milestone roadmap.
- [`CLAUDE.md`](../CLAUDE.md) — the file/namespace table and the project invariants.
- [`README.md`](../README.md) — build-file anatomy and CLI usage.
- The tests in `tests/` are the most precise spec: each `lib/<x>.tcl` has a matching
  `tests/<x>.test` that exercises it in isolation.
