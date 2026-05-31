# Tuck M2 — Design Spec

> Milestone 2 of the Tuck build system (see `DESIGN.md` for the full vision;
> `2026-06-01-tuck-m1-design.md` for the loading phase this builds on).
> Date: 2026-06-01

## 1. Scope

M2 delivers the **analysis phase** end to end and nothing more:

- A `ctx.*` command surface available to rule impls during analysis.
- An analysis driver that visits the target closure leaves-first and invokes each
  target's compiled rule impl.
- Construction of a **static action graph** — source/declared artifacts and static
  action nodes.
- Two CLI commands to observe the result: `tuck analyze <label>` and
  `tuck query actions <label>`.

**Explicitly out of scope for M2:** execution (M3), dynamic actions/thunks (M4),
content hashing and output-base materialization (M5). `cmd` strings are stored
verbatim — no `$OUT`/`$SRCS` substitution and no on-disk paths are computed.

`genrule` remains **user-defined in the root `TUCK` file** (consistent with M1); it
is the worked example and test fixture, not a shipped built-in.

## 2. The `ctx` object

`ctx` *is* the M1 target node — the dict `{label rule attrs package deps}`. Analysis
passes the node to the impl as `$ctx`; every `ctx.*` command takes it as the first
argument. No new structure is introduced.

The compiled impl (from M1, `__tuck_impl_<rule> {ctx} <body>`) is invoked as:

```tcl
$rulesInterp eval [list __tuck_impl_<rule> $node]
```

## 3. Command surface

Internal procs live in `::tuck::ctx::*` (matches DESIGN §8). They are surfaced into
the rules interpreter under the dotted names from §7.1/§7.3 via aliases, e.g.
`$rules alias ctx.attr ::tuck::ctx::attr`. The procs run in the root interpreter and
read/mutate `::tuck::graph::*`.

| Surface command | Returns / effect |
|---|---|
| `ctx.attr $ctx <key>` | Type-resolved value (see §3.1) |
| `ctx.label $ctx` | `dict get $ctx label` |
| `ctx.package $ctx` | `dict get $ctx package` |
| `ctx.declare_output $ctx <relpath>` | Registers a declared artifact, records it under this target's outputs, returns its id |
| `ctx.action $ctx inputs <ids> outputs <ids> cmd <list> ?env <dict>?` | Registers a static action node, returns its id |
| `ctx.dep_outputs $ctx <label>` | The declared output ids of an already-analysed dependency |

### 3.1 `ctx.attr` resolution by schema type

Resolution is driven by the attr's declared type in the rule schema:

- `sources` → a list of **source artifact ids**. Each value `p` becomes
  `source:<pkg>/<p>` (repo-relative; if the package is the root `""`, just
  `source:<p>`). Each id is registered in `graph::artifacts`.
- `dep` → the canonical label (string). `deps` → list of canonical labels.
- `string` / `int` / `bool` / `list` / `output` → the raw stored value.
- A key **not in the rule's schema** → error `tuck: ctx.attr: no attribute '<key>'`.
- A key in the schema but absent from attrs (optional, no default — M1 validation
  only stores provided or defaulted attrs) → empty value (`{}`).

`ctx.dep_outputs $ctx <label>` then maps a dep label to that dependency's declared
output artifact ids (looked up in `graph::target_outputs`).

## 4. Action-graph data structures (DESIGN §6)

- **Source artifact:** `{type source path <repo-rel>}`; id `source:<repo-rel>`.
- **Declared artifact:** `{type declared target <label> relpath <rel>}`;
  id `declared:<label>:<relpath>`.
- **Action node:**
  `{id <label>#<n>  target <label>  inputs {ids}  outputs {ids}  cmd <list>  env <dict>  dynamic false}`.
  `<n>` is a per-target sequential index, so ids are deterministic
  (e.g. `//app:hello#0`).

Artifact ids are **opaque dict keys** — never parsed back into components — so the
colons inside labels are harmless.

### 4.1 New global stores

- `::tuck::graph::artifacts` — dict: artifact-id → artifact.
- `::tuck::graph::actions` — dict: action-id → action node. Insertion order follows
  analysis (leaves-first), which the printer relies on.
- `::tuck::graph::target_outputs` — dict: label → list of declared output ids;
  populated by `ctx.declare_output`, read by `ctx.dep_outputs`.

A per-target action counter (reset per analysis run) generates the `#<n>` suffix.

## 5. Analysis driver

`::tuck::phase::analyse {labels}`:

1. `load_closure` the packages of `labels` (M1), then `::tuck::graph::validate`.
2. `topo_sort` the closure → leaves-first order.
3. For each target in order:
   - Fetch its node; look up its rule's compiled impl name (`__tuck_impl_<rule>`).
   - If the rule has no impl (empty), error `tuck: rule <rule> has no impl`.
   - Invoke `$rulesInterp eval [list <implname> $node]`.
4. The impl's `ctx.*` calls populate the three stores.

Leaves-first ordering guarantees a dependency's outputs are registered before any
dependent calls `ctx.dep_outputs` on it.

## 6. Modules

New files:

```
lib/action.tcl   # ::tuck::graph — artifacts/actions/target_outputs stores, id
                 #   helpers, register_source / register_declared / register_action
lib/ctx.tcl      # ::tuck::ctx::* command procs + ::tuck::ctx::install (aliases
                 #   the six commands into the rules interp)
lib/analyse.tcl  # ::tuck::phase::analyse driver
```

Modified files:

- `lib/loader.tcl`: `::tuck::phase::setup` also calls `::tuck::ctx::install` on the
  rules interp; `::tuck::reset` also clears `graph::artifacts`, `graph::actions`,
  `graph::target_outputs`, and the action counter.
- `tuck.tcl`: source the new files; add `analyze` and `query actions` dispatch and a
  shared action printer.

## 7. CLI

- `tuck analyze <label>` — analyse the target's closure, print **every** action,
  leaves-first.
- `tuck query actions <label>` — analyse the closure, print only the actions whose
  `target` equals `<label>`.

Shared printer format:

```
//lib:util#0
  inputs:  source:lib/util.c
  outputs: declared://lib:util:util.o
  cmd:     cc -c lib/util.c -o util.o
```

Multiple inputs/outputs are space-joined on the one line. Actions print in
`graph::actions` insertion order (leaves-first).

## 8. Error handling

`tuck:`-prefixed errors, consistent with M1; the top-level catch in `tuck.tcl`
prints to stderr and exits non-zero. Specific cases:

- A target whose rule has no impl: `tuck: rule <rule> has no impl`.
- `ctx.attr` on an unknown key: `tuck: ctx.attr: no attribute '<key>'`.
- `ctx.dep_outputs` on a label that has not been analysed (not in
  `target_outputs`): `tuck: ctx.dep_outputs: <label> has no analysed outputs`.
- `ctx.action` missing a required named arg: `tuck: ctx.action: missing <arg>`.

## 9. Testing (TDD with `tcltest`)

- **action.test** — id helpers; `register_action` produces per-target sequential
  ids; `register_source` / `register_declared` are idempotent and store the right
  artifact dicts.
- **ctx.test** — `ctx.attr` resolution per type (sources→ids, dep/deps→labels,
  scalar→raw); `ctx.label` / `ctx.package`; `ctx.declare_output` registers the
  artifact, returns its id, and feeds `target_outputs`; `ctx.dep_outputs`; error on
  unknown attr key.
- **analyse.test** — fixture repo with a real `genrule` impl and an `app → lib` dep
  edge; assert the registered actions/artifacts and that `dep_outputs` wired `lib`'s
  declared output into `app`'s action inputs; assert the no-impl error.
- **integration.test** (extend) — `tuck analyze //app:hello` full dump;
  `tuck query actions //app:hello` filtered to that target.

The `genrule` impl used in fixtures:

```tcl
impl {
    set out [ctx.declare_output $ctx [ctx.attr $ctx out]]
    set ins [ctx.attr $ctx srcs]
    foreach d [ctx.attr $ctx deps] {
        lappend ins {*}[ctx.dep_outputs $ctx $d]
    }
    ctx.action $ctx inputs $ins outputs [list $out] cmd [ctx.attr $ctx cmd]
}
```

## 10. Definition of done

- `tuck analyze <label>` and `tuck query actions <label>` work against fixture repos.
- The action graph is built leaves-first with deterministic ids; `dep_outputs`
  correctly threads dependency outputs into dependent inputs.
- All error cases produce clear `tuck:`-prefixed messages.
- All `tcltest` suites green.
