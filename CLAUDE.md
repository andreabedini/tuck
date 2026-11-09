# CLAUDE.md

Guidance for working in the Tuck repository.

## What this is

Tuck is a hermetic, two-phase build system embedded in TCL, inspired by Buck2. The
authoritative design is [`DESIGN.md`](DESIGN.md); the per-milestone spec and plan are
under `docs/superpowers/`. **Milestones 1 (loading), 2 (analysis) and 3 (execution,
single-threaded, pure-Tcl directory sandbox) are implemented; dynamic actions (M4) are
next.**

## Toolchain

- Language: **Tcl 9.0+** (`tclsh`). Core + built-in `tcltest` only — no external packages.
- Version control: **Jujutsu (`jj`)**, not git. The working copy is always a commit;
  new files are auto-tracked (no staging). Finalize a change with `jj commit -m "..."`.

## Running tests

```sh
tclsh tests/all.tcl        # full suite
tclsh tests/<module>.test  # one suite, e.g. tests/label.test
```

A clean run ends with `Total N Passed N Skipped 0 Failed 0` and exits 0.

## Workflow conventions

- **TDD, always.** Write the failing test, confirm it fails for the right reason,
  implement the minimum to pass, confirm green, then commit. This is how M1 was built;
  keep it up.
- **Small, focused commits** — one logical change each.
- One namespace per concern; keep files focused. `tuck.tcl` only wires CLI → phases —
  put logic in `lib/`, not the entry point.
- Prefer `rg` over `grep -r`.

## Architecture

Source is in `lib/`, one namespace per file:

| File | Namespace | Responsibility |
|------|-----------|----------------|
| `lib/config.tcl` | `::tuck::config` | repo-root detection (walk up for `.tuck/`) |
| `lib/label.tcl`  | `::tuck::util`   | label parse / canon / resolution |
| `lib/rules.tcl`  | `::tuck`         | rule registration, attr-schema validation |
| `lib/target.tcl` | `::tuck`         | target-node registration, dep extraction |
| `lib/graph.tcl`  | `::tuck::graph`  | dangling-dep validation, topo-sort (cycle detect) |
| `lib/loader.tcl` | `::tuck::phase`  | interpreter setup, per-file loading, lazy closure |
| `lib/action.tcl` | `::tuck::graph`  | action-graph stores (artifacts/actions/target_outputs) + helpers |
| `lib/ctx.tcl`    | `::tuck::ctx`    | the `ctx <subcmd>` command for rule impls; `dispatch` forwards to accessors with the node curried by analysis; `install` aliases `ctx` into the rules interp |
| `lib/analyse.tcl`| `::tuck::phase`  | analysis driver: leaves-first impl invocation |
| `lib/sandbox.tcl`| `::tuck::sandbox`| run one action in a fresh directory: stage declared inputs as symlinks, clear the env, collect outputs |
| `lib/execute.tcl`| `::tuck::phase`  | execution driver: plan needed actions leaves-first, staleness via `tuck-out/.db`, run stale ones |
| `tuck.tcl`       | `::tuck::cmd`/`main` | CLI parse + dispatch, top-level error catch |

### Interpreter model (the core of hermeticity)

Three interpreters, all child interps created with `interp create -safe` (which is what
removes `open`/`exec`/`file`/`package` — hermeticity is the safe-interp boundary, with
narrow aliases as the only escape hatch):

- **loader** — fresh per BUILD/TUCK file, deleted after. Exposes only `targets` and
  `rules` (aliased back to the root interp).
- **target** — shared, persistent. Holds rule constructors. `targets {body}` is eval'd here.
- **rules** — shared, persistent. Holds `tuck::rule` and impl procs. `rules {body}` is eval'd here.

The root interp reads files from disk and orchestrates; child interps never touch the
filesystem.

### Key invariants & rules

- **Rules are repo-global, defined only in the root `TUCK` file**, loaded
  deterministically *before* any lazy package loading. Do NOT accumulate rules "as
  packages load" — lazy load order is undefined, so that would be order-dependent. (This
  corrects DESIGN §8, which is annotated inline.)
- **Target syntax is dict-style**: a constructor takes one brace block treated as a
  *dict of attributes* (pure data, never eval'd as a script). This corrects DESIGN §9's
  Python-like `name = "..."` form, which is not valid TCL.
- **Rule `impl` is an inline body**, not a proc name: ``impl { ...uses the `ctx` command... }``.
  `register_rule` compiles it into `__tuck_impl_<name> {} <body>` (no parameters) in the
  rules interp at registration time (so analysis always calls a real named proc). Note this
  re-enters the rules interp from inside the `tuck::rule` alias — that is intentional
  and works. The body uses `ctx attr`, `ctx declare_output`, `ctx action`, etc. — the
  target node is curried into the `ctx` alias by analysis, not passed as an argument.
  Helper procs defined in the `rules` block call `ctx ...` directly (the alias is global
  to the rules interp during analysis); they take no `ctx` parameter.
- **Loading is lazy/transitive**: load the requested package, follow deps to other
  packages until the graph closes. `//...` is the only eager (tree-scanning) path.
- Loading-phase invariants, all enforced with `tuck:`-prefixed errors: target names
  match `[A-Za-z0-9_.+=,@~-]+` (not `.`/`..`; they become output path components), package paths have
  no empty or dot-led components (checked in `load_package`), no duplicate
  labels, all deps resolve to known targets, no dependency cycles.
- `topo_sort` is post-order DFS → **leaves-first** order, and detects cycles.
- **Analysis is leaves-first**: `analyse` topo-sorts the closure so a dependency's
  `declare_output`s are recorded before any dependent calls `ctx dep_outputs`. Analysis
  curries the target node into the `ctx` alias (`$rules alias ctx ::tuck::ctx::dispatch $node`)
  once per target before invoking its impl; `ctx <subcmd>` forwards to the accessor with
  that node. A single live binding is safe because analysis is strictly sequential and
  impls never nest. Action ids are per-target
  sequential (`<label>#<n>`); `cmd` is stored verbatim (no `$OUT`/path resolution
  until execution). A non-existent analyse target yields `tuck: no such target: ...`.

- **Execution (M3)**: every artifact has an *exec path* relative to the repo root:
  sources keep their path, declared outputs go to `tuck-out/<pkg>/__<name>__/<rel>`
  (`::tuck::graph::exec_path`, exposed to impls as `ctx path`). Commands name files by
  exec path; there is no `$OUT`/`$SRCS` substitution. `ctx declare_output <rel> -private`
  registers an artifact without publishing it to `dep_outputs`. `ctx action` rejects
  unknown artifacts, outputs owned by another target, a second producer for an
  artifact (`::tuck::graph::producers`), an input or output listed twice, and `cmd` words Tcl `exec` would read as
  redirections (`>x`, `2>@1`, `<x`, `|`, trailing `&`) — shell features go in `sh -c`.
- **The sandbox changes process-wide state**: `::tuck::sandbox::run` `cd`s into the
  sandbox and replaces `::env` for the duration of the `exec`, restoring both in a
  `finally`. Safe only because execution is single-threaded; M6 must change this.
  Never `array unset ::env` (it drops the env traces) — unset elements one by one.
- Toolchain hermeticity is the user's job (as in Buck2): the sandbox passes the host
  `PATH` through.

## Gotchas

- Setting a qualified variable like `::tuck::_libdir` requires the namespace to exist
  first (`namespace eval ::tuck {}`).
- In `tcltest`, `makeDirectory` reuses a directory if called with the same name —
  generate unique fixture names to avoid cross-test contamination.
- Building a Tcl `list` from a value containing newlines brace-quotes it; in tests,
  compare command output as a plain string rather than via `list`.
