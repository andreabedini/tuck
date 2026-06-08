# Design: `ctx` as a node-bound ensemble command

**Date:** 2026-06-08
**Status:** Approved, pending implementation plan
**Scope:** Refactor the rule-impl `ctx` surface. No new build-system capability.

## Problem

Rule impls currently access their context through six dotted aliases that each
re-thread the target node as an explicit argument:

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

Re-passing `$ctx` on every call is verbose and noisy. The obvious "fix" —
dumping attribute values into the impl scope as bare variables (`$out`,
`$srcs`) — is rejected: it discards `ctx.attr`'s type resolution and side
effects (`sources` registers artifacts, `dep`/`deps` canonicalize), forces
eager resolution of unused attributes (changing the action graph based on
schema rather than use), collides with body locals and helper temporaries,
loses schema-checked typo detection, and splits the mental model (attributes
as magic vars, operations still through `ctx`). This matches Bazel/Buck2, which
deliberately namespace attributes under `ctx.attr.<name>`.

The real wart is the threaded `$ctx`, not the namespace. The fix removes the
threading while keeping a single uniform surface.

## Surface

A single command `ctx` with subcommands replaces the six dotted aliases. The
node is bound for the author, not passed:

```tcl
ctx attr <key>          ;# was: ctx.attr $ctx <key>
ctx label               ;# was: ctx.label $ctx
ctx package             ;# was: ctx.package $ctx
ctx declare_output <p>  ;# was: ctx.declare_output $ctx <p>
ctx action <k> <v> ...  ;# was: ctx.action $ctx <k> <v> ...
ctx dep_outputs <label> ;# was: ctx.dep_outputs $ctx <label>
```

After the refactor the genrule impl reads:

```tcl
impl {
    set out [ctx declare_output [ctx attr out]]
    set ins [ctx attr srcs]
    foreach d [ctx attr deps] {
        lappend ins {*}[ctx dep_outputs $d]
    }
    ctx action inputs $ins outputs [list $out] cmd [ctx attr cmd]
}
```

`ctx attr` still routes through `::tuck::ctx::attr`, so `sources`/`dep`/`deps`
type resolution and the unknown-attribute error are unchanged.

**Compatibility:** the dotted `ctx.<x> $ctx` aliases are removed entirely — not
kept alongside. M2 is freshly implemented and only a handful of test fixtures
use the old form, so a clean single surface is preferred over two idioms.

## Binding mechanism

The node is **curried into the `ctx` alias**, rebound once per target during
analysis. This is the Tcl-idiomatic way to bind context without a global
variable or a threaded argument.

- `::tuck::ctx::install` aliases `ctx` into the rules interp pointing at a
  dispatcher. The node is unknown at install time, so `install` sets an initial
  binding that errors if `ctx` is used before analysis binds a real node.
- `::tuck::phase::analyse`, inside its `foreach label` loop, rebinds the alias
  per iteration before invoking the impl:
  ```tcl
  $::tuck::interp::rules alias ctx ::tuck::ctx::dispatch $node
  $::tuck::interp::rules eval [list $impl]
  ```
- `::tuck::ctx::dispatch {node subcmd args}` validates `subcmd` against the
  known set and forwards: `::tuck::ctx::$subcmd $node {*}$args`.

**Why a single live binding is safe:** analysis is strictly sequential and
leaves-first — one impl runs at a time and impls never nest, so there is never
more than one "current node." The curried alias is therefore unambiguous.

## Compiled impl and helpers

- `::tuck::register_rule` compiles the body to `proc __tuck_impl_<name> {}
  <body>` — the `ctx` formal parameter is dropped. `analyse` calls it with no
  argument.
- Helper procs defined in the `rules` block no longer take or pass `$ctx`.
  Because the `ctx` alias is a command global to the rules interp during
  analysis, a helper calls `ctx attr x` directly. So
  `proc helper {ctx} {... ctx.attr $ctx x}` becomes
  `proc helper {} {... ctx attr x}`. This is the one behavioral change for
  rule authors and must be reflected in the docs, which currently document the
  `{ helper $ctx }` pattern.

## Error handling

- Unknown subcommand → `tuck: ctx: unknown subcommand '<x>'`.
- `ctx` used before a node is bound (outside analysis) →
  `tuck: ctx: no target bound (used outside analysis)`.
- All existing per-accessor errors are preserved, with message text respelled
  from the dotted form to the subcommand form:
  - `tuck: ctx.attr: ...` → `tuck: ctx attr: ...`
  - `tuck: ctx.dep_outputs: ...` → `tuck: ctx dep_outputs: ...`
  - `tuck: ctx.action: ...` → `tuck: ctx action: ...`

## Files touched

| File | Change |
|------|--------|
| `lib/ctx.tcl` | Rewrite `install` to alias the single `ctx` → `dispatch` with an initial unbound (erroring) binding; add `dispatch`; respell the three error strings. The six accessor procs are otherwise unchanged. |
| `lib/rules.tcl` | Compile impl as `proc __tuck_impl_<name> {} <body>` (drop `ctx` param). |
| `lib/analyse.tcl` | Per-node: rebind the `ctx` alias to curry the node, then `eval [list $impl]` with no node arg. |
| `tests/ctx.test` | Drive through `ctx <subcmd>` instead of `ctx.<x> $ctx`; assert respelled error strings; add unknown-subcommand and out-of-analysis tests. |
| `tests/analyse.test`, `tests/integration.test` | Migrate the genrule impl fixtures to the new surface. |
| `tests/rules.test` | Update the `inline-impl` test (body no longer references `$ctx`; impl is a zero-arg proc). |
| `CLAUDE.md`, `docs/superpowers/specs/2026-06-01-tuck-m2-design.md` | Update the impl/`ctx` surface description and the `{ helper $ctx }` note. |

## Testing (TDD)

Failing test first at each step:

1. **`dispatch` unit** (`ctx.test`): bind a node, assert `ctx attr name`
   resolves; assert unknown-subcommand and out-of-analysis errors.
2. **Migrate existing `ctx.test`** cases to the new surface — type resolution,
   label/package, dep_outputs error, action register/missing-arg.
3. **`rules.test`**: impl compiles to a zero-arg proc; `inline-impl` body runs
   via the bound `ctx`.
4. **`analyse.test` / `integration.test`**: end-to-end with migrated genrule
   fixtures. Regression bar: the produced action graph (artifacts/actions) must
   be identical to today's output.

A clean run ends `Total N Passed N Skipped 0 Failed 0` and exits 0.

## Out of scope

- No change to attribute type semantics, action registration, or the loading
  phase.
- No new `ctx` subcommands beyond the existing six.
