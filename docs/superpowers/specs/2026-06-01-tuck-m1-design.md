# Tuck M1 — Design Spec

> Milestone 1 of the Tuck build system (see `DESIGN.md` for the full vision).
> Date: 2026-06-01

## 1. Scope

M1 delivers the **loading phase** end to end and nothing more:

- Repo-root detection.
- Lazy / transitive loading of `BUILD` files.
- Target graph construction, with attr-schema validation and dep extraction.
- Label parsing, canonicalization, and resolution.
- Topological sort with cycle detection.
- Two read-only CLI commands: `tuck targets <pattern>` and `tuck query deps <label>`.

**Explicitly out of scope for M1:** the analysis phase, the action graph,
artifact declaration, execution, and dynamic actions. Rule **impl** procs are
parsed and stored but never invoked in M1.

## 2. Key decisions (resolved during brainstorming)

1. **Target syntax is dict-style.** A rule constructor takes a single brace
   block treated as a *dict of attributes* (pure data, never eval'd as a
   script):

   ```tcl
   targets {
       genrule {
           name hello
           srcs {main.c util.c}
           out  hello
           cmd  {cc -o $OUT $SRCS}
       }
   }
   ```

   This corrects DESIGN §9, which showed a Python-like `cc_binary(name = "hello", ...)`
   form that is not valid TCL and would contradict the "TCL is the language /
   no separate DSL" principle.

2. **Loading is lazy / transitive.** Loading the requested target reads only its
   package's `BUILD`, then follows deps to other packages on demand until the
   graph closes. Packages never referenced are never read.

3. **Rules are repo-global, defined only in the root `TUCK` file** (Option 1).
   The root `TUCK` is loaded first, deterministically, before any package. Its
   `rules {}` block is the single source of rule definitions. Package `BUILD`
   files contain only `targets {}`.

   This is a **correction to DESIGN §8**: the singular shared `interp::rules` /
   `interp::target` are only sound if their contents are established *before*
   lazy loading begins. Accumulating rules "as packages load" is order-dependent
   and therefore a bug, because lazy load order is undefined and unstable.
   Per-package `rules {}` blocks (DESIGN §7.1/§9) are deferred; when reintroduced
   they must use freshly-seeded per-package interps so package-local rules cannot
   leak and load order stays irrelevant. (This correction is also recorded inline
   in DESIGN.md §8.)

## 3. Definitions

- **Repo root:** the nearest ancestor directory containing a `.tuck/` marker.
- **Package:** a directory under the root containing a `BUILD` file. Its identity
  is its path relative to the root, slash-normalized (e.g. `tools/hello`). The
  root package is the empty string `""`.
- **Target:** a node living in exactly one package, addressed by a canonical
  label.
- **Label (canonical):** the string `//pkg:name`.
  - `//pkg:name` — fully qualified.
  - `:name` — relative; resolves against the package of the BUILD file being
    evaluated.
  - `//pkg` — shorthand for `//pkg:<basename(pkg)>` (the last path segment).

## 4. Architecture — interpreter model

Three interpreters:

| Interp | Lifetime | Exposes | Purpose |
|---|---|---|---|
| **loader** | fresh per BUILD/TUCK file, deleted after | `targets`, `rules` only | sandbox that evaluates one file's top level |
| **target** | shared, persistent | rule constructors (`genrule`, …) | `targets {body}` is eval'd here |
| **rules**  | shared, persistent | `tuck::rule`, `proc` (later `ctx::*`) | `rules {body}` is eval'd here |

No file I/O, `exec`, `open`, or `package require` is aliased into any child
interpreter.

### 4.1 Load sequence for one file in package `P`

1. Root sets the "current package" = `P`.
2. Root creates a fresh **loader** interp, aliases `targets` and `rules` back to
   root, evaluates the file, then deletes the loader interp.
3. `rules {body}` (root TUCK only) → root evaluates `body` in the shared **rules**
   interp. `tuck::rule name {...}` (aliased to root) registers the schema + impl
   name in `graph::rules` and installs a constructor alias `name` in the shared
   **target** interp.
4. `targets {body}` → root evaluates `body` in the shared **target** interp. Each
   constructor call (e.g. `genrule {…}`) is aliased to root, which:
   - validates the attr dict against the rule's schema,
   - canonicalizes the target's label against the current package,
   - extracts deps (attrs whose schema type is `dep`/`deps`),
   - registers the target node in `graph::targets`.

Because rules come only from the root `TUCK` (loaded first), the shared interps'
contents are deterministic and package load order is irrelevant.

## 5. Modules / file layout

```
tuck.tcl                 # entry point: arg parsing, dispatch to query/targets
lib/
  config.tcl             # ::tuck::config — root detection, paths
  label.tcl              # ::tuck::util — label_parse, label_canon, pattern match
  loader.tcl             # ::tuck::phase::load — interp setup, lazy traversal
  rules.tcl              # ::tuck::rule registration + attr-schema validation
  graph.tcl              # ::tuck::graph — target store, dep resolution, topo_sort
tests/                   # tcltest suites, one per module + integration suite
  fixtures/              # tiny throwaway repos (.tuck/, TUCK, BUILD files)
```

One namespace per concern, matching DESIGN §8. `tuck.tcl` only wires CLI → phases.

## 6. Data structures

- **Label:** canonical string `//pkg:name`. `label_parse` → `dict {pkg name}`;
  `label_canon pkg name` → string.
- **Target node** (DESIGN §5.1): `dict {label rule attrs package deps}`.
- **Rule** (`graph::rules`): `dict ruleName → {schema implName}`. `schema` =
  `dict attr → {type ... mandatory ... default ...}`.
- **Graph store:** `graph::targets` = `dict label → node`. Edges live in each
  node's `deps` list.

### 6.1 Attr types honored in M1

Per DESIGN §7.2: `string`, `int`, `bool`, `list`, `sources`, `dep`, `deps`,
`output`. M1 validates presence (`mandatory`), applies `default`, and uses
`dep`/`deps` to populate the node's dep set. (`sources` resolution to artifacts
is an M2+ concern; in M1 they remain strings.)

## 7. Control flow

```
tuck <cmd> <arg>
 1. config: find repo root by walking up for .tuck/; error if none.
 2. load root TUCK (if present) → populates graph::rules + target-interp
    constructors.
 3. resolve <arg> to seed label(s):
      - targets <pattern>: expand pattern to concrete labels.
      - query deps <label>: a single seed label.
 4. lazy load: worklist of packages. For each, load its BUILD (set current pkg,
    fresh loader interp, eval, delete interp), register its targets, enqueue the
    packages of any not-yet-loaded deps. Repeat until the closure is loaded.
 5. validate invariants (§8).
 6. produce output:
      - targets: print matched labels, sorted.
      - query deps: topo_sort the seed's closure, print leaves-first.
```

### 7.1 Pattern matching for `tuck targets`

- `//pkg:name` — exact target.
- `//pkg` — the package's default target (`//pkg:<basename>`).
- `//pkg:...` or `//pkg/...` — all targets in the package / package subtree.
  The subtree case scans directories under `pkg` for `BUILD` files — the single
  eager exception, scoped to the pattern's subtree.

## 8. Invariants & error handling (DESIGN §5.2)

Checked after the closure is loaded, before output:

- **No duplicate labels** — second registration of a label errors.
- **All deps resolve** — every dep label names a known target; a dangling edge
  errors and names the offending dependency.
- **No cycles** — `topo_sort` detects a cycle and reports the participating
  labels.

All failures use TCL `error` with a `tuck:` message prefix. `tuck.tcl` catches at
the top level, prints to stderr, and exits non-zero.

## 9. Testing (TDD with `tcltest`)

- **label:** parse/canon round-trips, relative `:name` resolution, `//pkg`
  shorthand, malformed labels.
- **rules:** schema validation — missing mandatory attr, wrong type, defaults
  applied, dep extraction from `dep`/`deps`.
- **graph:** topo-sort ordering, cycle detection, dangling-dep error, duplicate-
  label error.
- **integration:** build small fixture repos under `tests/fixtures/` and assert
  `tuck targets` / `tuck query deps` output.
- **hermeticity:** a BUILD/TUCK file calling `exec` or `open` must fail.

## 10. Definition of done

- `tuck targets <pattern>` and `tuck query deps <label>` work against fixture
  repos.
- All invariants enforced with clear errors.
- Hermeticity verified by test.
- All `tcltest` suites green.
