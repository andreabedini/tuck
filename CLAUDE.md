# CLAUDE.md

Guidance for working in the Tuck repository.

## What this is

Tuck is a hermetic, two-phase build system embedded in TCL, inspired by Buck2. The
authoritative design is [`DESIGN.md`](DESIGN.md); the per-milestone spec and plan are
under `docs/superpowers/`. **Currently only Milestone 1 (the loading phase) is
implemented.**

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
- **Rule `impl` is an inline body**, not a proc name: `impl { ...uses $ctx... }`.
  `register_rule` compiles it into `__tuck_impl_<name> {ctx} <body>` in the rules
  interp at registration time (so analysis always calls a real named proc). Note this
  re-enters the rules interp from inside the `tuck::rule` alias — that is intentional
  and works. A body of `{ helper $ctx }` recovers the named-proc style.
- **Loading is lazy/transitive**: load the requested package, follow deps to other
  packages until the graph closes. `//...` is the only eager (tree-scanning) path.
- Loading-phase invariants, all enforced with `tuck:`-prefixed errors: no duplicate
  labels, all deps resolve to known targets, no dependency cycles.
- `topo_sort` is post-order DFS → **leaves-first** order, and detects cycles.

## Gotchas

- Setting a qualified variable like `::tuck::_libdir` requires the namespace to exist
  first (`namespace eval ::tuck {}`).
- In `tcltest`, `makeDirectory` reuses a directory if called with the same name —
  generate unique fixture names to avoid cross-test contamination.
- Building a Tcl `list` from a value containing newlines brace-quotes it; in tests,
  compare command output as a plain string rather than via `list`.
